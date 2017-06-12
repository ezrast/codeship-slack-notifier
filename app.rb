require 'json'
require 'logger'
require 'openssl'
require 'slack/post'
require 'sinatra/config_file'

class CodeshipSlackNotifier < Sinatra::Base
  set :server, :puma
  set :port, (ENV['PORT'] || 9876).to_i
  set :bind, '0.0.0.0'

  register Sinatra::ConfigFile
  config_file 'config.yml'

  Logger.class_eval { alias :write :'<<' }
  access_log = File.open(File.join(settings.root, 'log', "#{settings.environment}_access.log"), 'a+')
  access_log.sync = true
  access_logger = Logger.new(access_log)
  error_log = File.open(File.join(settings.root, 'log', "#{settings.environment}_error.log"), 'a+')
  error_log.sync = true

  configure do
    enable :logging
    use Rack::CommonLogger, access_logger
  end

  before { env['rack.errors'] = error_log }

  private

  def parse_body
    request.body.rewind
    @body = JSON.parse(request.body.read) rescue {}
    request.body.rewind
  end

  def handle_webhook
    parse_body
    halt 422 unless @body['build']
    halt 204 unless settings.branches_to_handle.include?(@body['build']['branch']) || settings.branches_to_handle.include?('all')
    notify_slack
  end

  def status_text(status)
    case status
    when 'testing'
      'is pending'
    when 'success'
      'succeeded'
    when 'error'
      'FAILED'
    when 'stopped'
      'was stopped'
    when 'waiting'
      'is waiting to start'
    when 'infrastructure_failure'
      'FAILED due to a Codeship error'
    when 'ignored'
      'was ignored because the account is over the monthly build limit'
    when 'blocked'
      'was blocked because of excessive resource consumption'
    else
      'did something weird...'
    end
  end

  def status_color(status)
    case status
    when 'testing'
      nil
    when 'success'
      'good'
    when 'error'
      'danger'
    when 'stopped'
      nil
    when 'waiting'
      nil
    when 'infrastructure_failure'
      'danger'
    when 'ignored'
      nil
    when 'blocked'
      'danger'
    else
      'danger'
    end
  end

  # def build_message
  #   build = @body['build']
  #   message = "<#{build['build_url']}|#{build['branch']}> build"
  #   message += " (<#{build['commit_url']}|#{build['commit_id'][0..6]}>) " if build['commit_id'] && build['commit_url']
  #   message += "#{message[-1] == ' ' ? '' : ' '}by #{build['committer']} " if build['committer']
  #   message += status_text(build['status'])
  #   message
  # end

  def build_attachment
    build = @body['build']
    [{
      fallback: "Build #{status_text(build["status"])} - #{build["message"]} on #{build["project_name"]} / #{build["branch"]} by #{build["committer"]} - #{build["build_url"]}",
      pretext: "<#{build["build_url"]}|Build #{status_text(build["status"])}>",
      color: status_color(build["status"]),
      fields: [
        { title: "Commit", value: "<#{build["commit_url"]}|#{build["message"]}>", short: false },
        { title: "Branch", value: "#{build["project_name"]} / #{build["branch"]}", short: true },
        { title: "Committer", value: build["committer"], short: true },
      ],
    }]
  end

  def notify_slack
    build = @body['build']
    if Array === settings.branches_to_handle
      branch_settings = settings.slack
    else
      branch_settings = settings.slack.to_h.merge settings.branches_to_handle[build['branch']].to_h
    end
    Slack::Post.configure(
      webhook_url: branch_settings['webhook_url'],
      username: branch_settings['username']
    )

    begin
      channels = branch_settings.fetch("channel-#{build['status']}")
    rescue KeyError
      channels = branch_settings['channel']
    end
    [*channels].compact.each do |channel|
      Slack::Post.post_with_attachments(nil, build_attachment, channel)
    end
  end

  public

  post '/handle' do
    handle_webhook
  end

  run! if __FILE__ == $0
end
