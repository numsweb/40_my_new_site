class User < ActiveRecord::Base
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :trackable, :validatable
  attr_accessible :email, :password, :password_confirmation
  
  attr_reader :sign_in_count, :current_sign_in_at, :current_sign_in_ip
  
  validates_presence_of :email
  
end
