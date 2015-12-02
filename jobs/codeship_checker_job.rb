require 'json'
require 'open-uri'
require 'slack/post'
require 'sucker_punch'

class CodeshipCheckerJob
  include SuckerPunch::Job

  def perform(settings, git_commit)
    @settings = settings
    @git_commit = git_commit

    attempted_build_finds = 0
    testing_notified = false
    waiting_notified = false
    loop do
      build = builds.find {|b| b['commit_id'] == @git_commit}
      unless build
        return if attempted_build_finds > (settings.codeship['attempted_build_finds'] || 5).to_i
        attempted_build_finds += 1
        sleep 3
        next
      end

      started_monitoring = Time.now.to_i
      if build['status'] == 'testing'
        notify_slack(build) unless testing_notified
        testing_notified = true
        sleep 10
      elsif build['status'] == 'waiting'
        notify_slack(build) unless waiting_notified
        waiting_notified = true
        sleep 10
      elsif ['success', 'error'].include?(build['status'])
        return notify_slack(build)
      end

      if Time.now.to_i - started_monitoring > (settings.codeship['wait_timeout'] || 1500).to_i
        return notify_slack({}, 'Wait timeout of 1500 seconds exceeded')
      end
    end
  end

  private

  def builds
    JSON.parse(open("https://codeship.com/api/v1/projects/#{@settings.codeship['project_id']}.json?api_key=#{@settings.codeship['api_key']}").read)['builds']
  end

  def build_message(build)
    build_url = "https://codeship.com/projects/#{@settings.codeship['project_id']}/builds/#{build['id']}"
    status_text = case build['status']
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
    "<#{build_url}|#{build['branch']} build>#{build['github_username'] ? " by #{build['github_username']}" : ''} #{status_text}"
  end

  def notify_slack(build, message = false)
    Slack::Post.configure(
      webhook_url: @settings.slack['webhook_url'],
      username: @settings.slack['username']
    )
    Slack::Post.post(message || build_message(build), @settings.slack['channel'])
  end
end
