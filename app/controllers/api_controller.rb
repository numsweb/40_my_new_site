class ApiController < ApplicationController
  
  def get_users
    @users = User.all
    respond_to do |format|
      format.xml  {render :xml => @users.to_xml}
      format.json {render :json => @users.to_json}
    end
    #render :xml => @users
  end
  
  
  def get_user
    @user = User.find(params[:id])
    respond_to do |format|
      format.xml  {render :xml => @user.to_xml}
      format.json {render :json => @user.to_json}
    end
  end
  
  
  
end