require 'addressable/uri'
require 'slack_response_messages'
class FormatError < StandardError; end

class UberCommand
  VALID_COMMANDS = %w(
    ride
    estimate
    help
    accept
    share
    status
    cancel
    trigger_error
    test_resque
  )
  include UberCommandFormatters

  attr_reader :bearer_token
  def initialize(bearer_token, user_id, response_url)
    @bearer_token = bearer_token
    @user_id = user_id
    @response_url = response_url
  end

  def run(user_input_string)
    input = user_input_string.split(" ", 2) # Only split on first space.

    return SlackResponse::Errors::UNKNOWN_COMMAND_ERROR if input.empty?

    command_name = input.first.downcase

    command_argument = input.second.nil? ? "" : input.second.downcase

    if invalid_command?(command_name) || command_name.nil?
      return SlackResponse::Errors::UNKNOWN_COMMAND_ERROR
    end

    begin
      self.send(command_name, command_argument)
    rescue FormatError => e
      return e.message
    end
  end

  private

  def estimate(user_input_string)
    origin_lat, origin_lng, destination_lat, destination_lng =
      parse_start_and_end_coords(user_input_string, SlackResponse::Errors::ESTIMATES_FORMAT_ERROR)

    product_id = UberAPI.get_default_product_id_for_lat_lng(start_lat, start_lng)
    return [
      "Sorry, we did not find any Uber products available near #{start_addr}.",
      "Can you try again with a more precise address?"
    ].join(" ") if product_id.nil?

    # begin
    body = {
      "start_latitude" => origin_lat,
      "start_longitude" => origin_lng,
      "end_latitude" => destination_lat,
      "end_longitude" => destination_lng,
      "product_id" => product_id
    }

    GetRideEstimateJob.perform_later(start_addr, end_addr, body, bearer_header, @slack_url)

    "All right. Asking Uber for your estimate now."
  end

  def help(_) # No command argument.
    SlackResponse::Messages::HELP_TEXT
  end

  def share(_) # No command argument.
    ride = Ride.where(user_id: @user_id).order(:updated_at).last
    return "Sorry, we couldn't find a ride for you to share." if ride.nil?

    request_id = ride.request_id

    map_response = UberAPI.request_map_link(request_id)
    link = JSON.parse(map_response.body)["href"]
    "Use this link to share your ride's progress: #{link}."
  end

  def status(_) # No command argument.
    ride = Ride.where(user_id: @user_id).order(:updated_at).last
    return "Sorry, we couldn't find any rides that you requested." if ride.nil?

    GetRideStatusJob.perform_later(ride.request_id, @slack_url)
    "Got it. Asking Uber for your ride's status now."
  end

  def cancel(_) # No command argument.
    ride = Ride.where(user_id: @user_id).order(:updated_at).last
    return "Sorry, we couldn't find a ride for you to cancel." if ride.nil?
    raise FormatError, SlackResponse::INVALID_RIDE if @ride.nil?

    CancelRideJob.perform_later(ride.request_id, bearer_header)

    "OK. Telling Uber to cancel your ride request."
  end

  def accept(stated_multiplier)
    @ride = Ride.where(user_id: @user_id).order(updated_at: :desc).limit(1).first
    raise FormatError, SlackResponse::Errors::INVALID_RIDE if @ride.nil?

    surge = @ride.surge_multiplier
    if surge >= 2.0 && (stated_multiplier.to_f != surge || !stated_multiplier.include?("."))
      return "That didn't work. Please reply */uber accept #{multiplier}* to confirm the ride."
    end

    if (Time.now - @ride.updated_at) > 5.minutes
      # TODO: Break out address resolution in #ride so that we can pass lat/lngs directly.

      return ride("#{origin_name} to #{destination_name}")
    else
      response = UberAPI.accept_surge(ride)
      if response.try(:code) == 200 || response.try(:code) == 202
        body = JSON.parse(response.body)
        @ride.update!(request_id: response_hash['request_id'])
        format_200_ride_request_response(@ride.origin_name, @ride.destination_name, body)
      else
        "Sorry but something went wrong. We were unable to request a ride."
      end
    end
  end

  def ride(user_input_string)
    origin_lat, origin_lng, destination_lat, destination_lng =
      parse_start_and_end_coords(user_input_string, SlackResponse::Errors::RIDE_REQUEST_FORMAT_ERROR)

    product_id = UberAPI.get_default_product_id_for_lat_lng(origin_lat, origin_lng)
    return [
      "Sorry, we did not find any Uber products available near '#{origin_name}'.",
      "Can you try again with a more precise address?"
    ].join(" ") if product_id.nil?

    body = {
      "start_latitude" => origin_lat,
      "start_longitude" => origin_lng,
      "end_latitude" => destination_lat,
      "end_longitude" => destination_lng,
      "product_id" => product_id
    }

    begin
      ride_estimate_hash = UberAPI.get_ride_estimate(body, bearer_header)
    rescue => e
      Rollbar.error(e, "UberCommand#ride")
      return [
        "Sorry, we weren't able to request a ride for that trip.",
        "Can you try again with a more precise address?"
      ].join(" ")
    end

    surge_multiplier = ride_estimate_hash["price"]["surge_multiplier"]
    surge_confirmation_id = ride_estimate_hash["price"]["surge_confirmation_id"]

    ride_attrs = {
      user_id: @user_id,
      start_latitude: origin_lat,
      start_longitude: origin_lng,
      end_latitude: destination_lat,
      end_longitude: destination_lng,
      origin_name: origin_name,
      destination_name: destination_name,
      product_id: product_id
    }

    if surge_confirmation_id
      ride_attrs['surge_confirmation_id'] = surge_confirmation_id
      ride_attrs['surge_multiplier'] = surge_multiplier
    end

    ride = Ride.create!(ride_attrs)

    return ask_for_surge_confirmation(surge_multiplier) if surge_multiplier > 1

    RideJob.perform_later(
      bearer_header,
      ride,
      origin_lat,
      origin_lng,
      destination_lat,
      destination_lng,
      origin_name,
      destination_name,
      product_id,
      @response_url
    )

    ack = ["Got it!", "Roger that.", "OK.", "10-4."].sample
    "#{ack} Pinging Uber to drive you from #{origin_name} to #{destination_name}..."
  end

  def reply_to_slack(response)
    payload = { text: response }

    RestClient.post(@response_url, payload.to_json)
  end

  def test_sidekiq(input)
    TestJob.perform_later(@response_url, input)
    "Enqueued test."
  end
end
