require "net/http"
require "rexml/document"

class Channel < ApplicationRecord
  has_many :videos, dependent: :destroy

  # Метод для создания/обновления канала по его ID
  def self.create_by_id(youtube_id)
    rss_url = "https://www.youtube.com/feeds/videos.xml?channel_id=#{youtube_id}"

    uri = URI.parse(rss_url)
    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    return nil unless response.is_a?(Net::HTTPSuccess)

    doc = REXML::Document.new(response.body)

    title_node = doc.elements["feed/title"]
    channel_title = title_node ? title_node.text : "Неизвестный канал"

    channel = find_or_initialize_by(youtube_channel_id: youtube_id)
    channel.title = channel_title
    channel.rss_url = rss_url
    channel.save
    channel
  end

  # НОВЫЙ МЕТОД: Скачивание видеороликов для конкретного канала
  def fetch_videos
    uri = URI.parse(rss_url)
    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    return false unless response.is_a?(Net::HTTPSuccess)

    doc = REXML::Document.new(response.body)

    # Проходимся циклом по каждому видео (<entry>) в XML-ленте
    doc.each_element("feed/entry") do |entry|
      video_id = entry.elements["yt:videoId"]&.text
      title = entry.elements["title"]&.text
      published_at = entry.elements["published"]&.text

      thumb_element = entry.elements["media:group/media:thumbnail"]
      thumbnail_url = thumb_element ? thumb_element.attributes["url"] : nil

      description = entry.elements["media:group/media:description"]&.text

      next if video_id.nil?

      video = videos.find_or_initialize_by(youtube_video_id: video_id)
      video.title = title
      video.published_at = published_at
      video.thumbnail_url = thumbnail_url
      video.description = description
      video.save
    end

    true
  end
end
