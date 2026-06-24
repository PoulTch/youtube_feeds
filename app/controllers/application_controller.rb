class ApplicationController < ActionController::Base
  # Запускаем метод load_sidebar_channels перед любым действием на сайте
  before_action :load_sidebar_channels

  private

  def load_sidebar_channels
    # Достаем все каналы и сортируем по названию от А до Я
    @sidebar_channels = Channel.order(:title)
  end
end
