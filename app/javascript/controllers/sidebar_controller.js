import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  toggle() {
    // Просто переключаем класс на теге body
    document.body.classList.toggle("sidebar-open")
  }
}
