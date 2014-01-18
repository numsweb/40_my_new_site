class ApiController < ApplicationController
  
  def get_users
    @users = User.all
    render :xml => User.array_to_xml(@users)
  end
  
  
  def get_user
    @user = User.find(params[:id])
    render :xml => @user.to_xml(@user)
  end
  
  
  
end