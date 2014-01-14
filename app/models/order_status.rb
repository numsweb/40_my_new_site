class OrderStatus < ActiveRecord::Base
  
  # Simple information objects attached to orders
  # to keep a log of what's happened since it entered the system.
  
  belongs_to :order
  validates_presence_of :status, :order_id
  attr_accessible :status, :order_id
  default_scope :order => 'created_at ASC'
  
end
