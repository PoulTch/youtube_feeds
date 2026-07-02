class AddBannerUrlToChannels < ActiveRecord::Migration[8.0]
  def change
    add_column :channels, :banner_url, :string
  end
end
