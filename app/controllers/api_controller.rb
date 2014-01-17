class ApiController < ApplicationController
  
  def get_users
    @users = User.all
    render :xml => @users
  end
  
  
  def get_user
    @user = User.find(params[:id])
    render :xml => @user
  end
  
  
  
end