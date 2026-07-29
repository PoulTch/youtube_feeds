class AddSubscriberCountToChannels < ActiveRecord::Migration[8.0]
  def change
    add_column :channels, :subscriber_count, :integer
  end
end
