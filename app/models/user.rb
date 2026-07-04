class User < ApplicationRecord
  # Магия Rails: автоматически добавляет шифрование паролей и методы аутентификации
  has_secure_password

  # Защита от дубликатов: логин должен быть уникальным и заполненным
  validates :username, presence: true, uniqueness: true
end
