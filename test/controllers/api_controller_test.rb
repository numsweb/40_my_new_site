require 'test_helper'

class ApiControllerTest < ActionController::TestCase
  setup do
    @user = users(:one)
  end

  test "should get users" do
    get :get_users
    assert_response :success
    assert_not_nil assigns(:users)
    assigns(:users) == [users(:one)]
  end

  test "should get user" do
    get :get_user, :id => @user.id
    assert_response :success
    assert_not_nil assigns(:user)
  end


end
