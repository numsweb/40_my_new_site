require 'test_helper'

class UserTest < ActiveSupport::TestCase
  
 def test_should_create_user
    assert_difference 'User.count' do
      user = create_user
      assert !user.new_record?, "#{user.errors.full_messages.to_sentence}"
    end
  end

  def test_should_require_email
    assert_no_difference 'User.count' do
      u = create_user(:email => nil)
      assert_equal u.errors.messages, {:email=>["can't be blank", "can't be blank"]}
    end
  end
  
  protected
  def create_user(options = {})
    record = User.new({  :email => 'quire@example.com',
                         :password => 'quirequire',
                         :password_confirmation => 'quirequire' 
                        }.merge(options))
         record.save
         record
  end

end
