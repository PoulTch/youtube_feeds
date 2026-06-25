import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { youtubeId: String, videoId: Number } // Добавили videoId

  connect() {
    console.log("=== Профессиональный трекер NewPipe подключен! ===")
    this.videoId = this.youtubeIdValue
    this.railsId = this.videoIdValue // ID видео в базе данных Rails
    this.iframe = document.getElementById("youtube-player")

    this.iframe.addEventListener("load", () => {
      this.iframe.contentWindow.postMessage(JSON.stringify({ event: "listening", id: 1 }), "*")
    })

    this.messageHandler = (event) => {
      if (event.origin.includes("youtube.com")) {
        try {
          const data = JSON.parse(event.data)
          if (data.event === "infoDelivery" && data.info && data.info.currentTime !== undefined) {
            this.exactTime = data.info.currentTime
            this.totalDuration = data.info.duration || this.totalDuration
            
            if (this.exactTime > 0) {
              localStorage.setItem(this.videoId, this.exactTime);
              // Сохраняем процент просмотра в память браузера
              const percent = Math.round((this.exactTime / this.totalDuration) * 100);
              localStorage.setItem(`${this.videoId}_percent`, percent);
            }
          }
        } catch (e) {}
      }
    }

    window.addEventListener("message", this.messageHandler)
  }

  disconnect() {
    window.removeEventListener("message", this.messageHandler)
    
    // ОТПРАВЛЯЕМ ДАННЫЕ В БАЗУ ПРИ УХОДЕ СО СТРАНИЦЫ
    if (this.exactTime > 0 && this.totalDuration > 0) {
      const url = `/videos/${this.railsId}/save_progress`
      const token = document.querySelector('meta[name="csrf-token"]').getAttribute('content')

      // Используем sendBeacon — это самый надежный способ отправить данные вдогонку при закрытии вкладки
      const data = JSON.stringify({ current_time: Math.round(this.exactTime), total_time: Math.round(this.totalDuration) })
      fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": token },
        body: data
      })
    }
    console.log("=== Трекер отключен ===")
  }
}
