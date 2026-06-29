class FetchFullChannelArchiveJob < ApplicationJob
  queue_as :default

  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    return unless channel

    # Запускаем наш хардкорный метод, который мы только что написали в модели Channel
    channel.fetch_full_archive
  end
end
