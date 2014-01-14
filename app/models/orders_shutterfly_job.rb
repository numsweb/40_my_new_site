class OrdersShutterflyJob < ActiveRecord::Base
  belongs_to :order
  belongs_to :shutterfly_job

  attr_accessible :shutterfly_job_id, :order_id
end
