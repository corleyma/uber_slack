namespace :resque do
  task :setup

  desc "Start a Resque worker"
  task :work => [ :setup ] do
    require 'resque'

    worker = Resque::Worker.new
    worker.log "Starting worker #{self}"
    worker.work(ENV['INTERVAL'] || 5) # interval, will block
  end

  desc "Start multiple Resque workers. Should only be used in dev mode."
  task :workers do
    threads = []

    ENV['COUNT'].to_i.times do
      threads << Thread.new do
        system "rake resque:work"
      end
    end

    threads.each { |thread| thread.join }
  end

  # Preload app files if this is Rails
  task :preload => :setup do
    if defined?(Rails) && Rails.respond_to?(:application)
      # Rails 3
      Rails.application.eager_load!
    elsif defined?(Rails::Initializer)
      # Rails 2.3
      $rails_rake_task = false
      Rails::Initializer.run :load_application_classes
    end
  end

  namespace :failures do
    desc "Sort the 'failed' queue for the redis_multi_queue failure backend"
    task :sort do
      require 'resque'
      require 'resque/failure/redis'

      warn "Sorting #{Resque::Failure.count} failures..."
      Resque::Failure.each(0, Resque::Failure.count) do |_, failure|
        data = Resque.encode(failure)
        Resque.redis.rpush(Resque::Failure.failure_queue_name(failure['queue']), data)
      end
      warn "done!"
    end
  end
end