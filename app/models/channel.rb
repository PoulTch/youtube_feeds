class Channel < ApplicationRecord
  has_many :videos, dependent: :destroy
end
