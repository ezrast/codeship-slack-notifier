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
      'failed'
    when 'stopped'
      'was stopped'
    when 'waiting'
      'is waiting to start'
    when 'infrastructure_failure'
      'failed due to a Codeship error'
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

  def encode(raw)
    raw.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
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
    status = status_text(build["status"])
    message = encode build["message"].split("\n")[0]
    project = encode build["project_name"].sub("/", " / ")
    branch = encode build["branch"]
    committer = encode build["committer"]
    build_url = encode build["build_url"]

    return [{
      fallback: "Build #{status} - #{message} on #{project} / #{branch} by #{committer} - #{build_url}",
      title: "Build #{status}",
      title_link: build_url,
      color: status_color(build["status"]),
      fields: [
        { title: "Commit",
          value: "<#{encode build["commit_url"]}|#{message}>",
          short: false },
        { title: "Branch",
          value: "#{project} / #{branch}",
          short: true },
        { title: "Committer",
          value: committer,
          short: true },
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
