class User < ActiveRecord::Base
      
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :trackable, :validatable
  attr_accessible :email, :password, :password_confirmation
  
  validates_presence_of :email
  
  def self.array_to_xml(users)
    xml_data = ""
    response = ::Builder::XmlMarkup.new(:target => xml_data)
    response.instruct!
    response.users do
      users.each do |u|
        response.user do 
          response.id u.id
          response.email u.email
          response.sign_in_count u.sign_in_count
          response.current_sign_in_at u.current_sign_in_at
          response.current_sign_in_ip u.current_sign_in_ip
          response.last_sign_in_at u.last_sign_in_at
          response.last_sign_in_ip u.last_sign_in_ip
        end
      end
    end
    return xml_data
  end

  def to_xml(user)
    xml_data = ""
    response = ::Builder::XmlMarkup.new(:target => xml_data)
    response.instruct!
    response.user do 
      response.id id
      response.email email
      response.sign_in_count sign_in_count
      response.current_sign_in_at current_sign_in_at
      response.current_sign_in_ip current_sign_in_ip
      response.last_sign_in_at last_sign_in_at
      response.last_sign_in_ip last_sign_in_ip
    end
    return xml_data
  end
  
end
