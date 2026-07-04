class SessionsController < ApplicationController
  # Разрешаем открывать страницу входа без проверки авторизации (иначе будет бесконечный редирект)
  skip_before_action :check_login, only: [ :new, :create ]

  # Не выводим сайдбар на странице входа
  skip_before_action :load_sidebar_channels, only: [ :new, :create ]

  # 1. Показ формы входа
  def new
    render layout: false # Отключаем глобальный шаблон сайдбара, показываем только чистый экран входа
  end

  # 2. Обработка ввода логина и пароля
  def create
    user = User.find_by(username: params[:username].to_s.strip)

    if user && user.authenticate(params[:password])
      session[:user_id] = user.id
      # Жёсткий редирект на главную со статусом see_other для пробоя Turbo-зависаний
      redirect_to root_path, status: :see_other, notice: "Добро пожаловать!"
    else
      flash.now[:alert] = "Неверный логин или пароль"
      render :new, layout: false
    end
  end

  # 3. Выход из системы
  def destroy
    session[:user_id] = nil
    # Жёсткий редирект на вход с полной очисткой кэша
    redirect_to login_path, status: :see_other, notice: "Вы успешно вышли."
  end
end
