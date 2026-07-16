class CreateSolidCacheTables < ActiveRecord::Migration[8.0]
  def change
    create_table :solid_cache_tables do |t|
      t.timestamps
    end
  end
end
