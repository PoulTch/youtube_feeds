import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { youtubeId: String }

  connect() {
    console.log("=== Профессиональный трекер NewPipe подключен! ===")
    this.videoId = this.youtubeIdValue
    this.iframe = document.getElementById("youtube-player")

    // Как только iframe загрузится, отправляем ему команду начать трансляцию данных
    this.iframe.addEventListener("load", () => {
      console.log("=== Iframe загружен, отправляю команду инициализации API ===")
      this.iframe.contentWindow.postMessage(JSON.stringify({ event: "listening", id: 1 }), "*")
    })

    this.messageHandler = (event) => {
      if (event.origin.includes("youtube.com")) {
        try {
          const data = JSON.parse(event.data)
          
          // Ловим сообщения с текущим временем
          if (data.event === "infoDelivery" && data.info && data.info.currentTime !== undefined) {
            const exactTime = data.info.currentTime
            if (exactTime > 0) {
              localStorage.setItem(this.videoId, exactTime)
              console.log(`Точное время из плеера: ${Math.round(exactTime)} сек`)
            }
          }
        } catch (e) {
          // Игнорируем не-JSON сообщения
        }
      }
    }

    window.addEventListener("message", this.messageHandler)
  }

  disconnect() {
    window.removeEventListener("message", this.messageHandler)
    console.log("=== Трекер отключен ===")
  }
}
