class HomeController < ApplicationController
  layout "application"
  def index
  end
  
  def about
    
  end
  
  def support
    
  end
  
  def clients
    
  end
  
  
  def support
    
  end
  
  def design
    
  end
  
  def success
    
  end
  
  def services
    
  end
  
  
  
  def analytics
    #lets get the View to send us some dates, then plot a monthly total
    #for the intervening periods
    if request.post?
      #code
      @start_date = Time.parse("#{params[:start_date][:day]}-#{params[:start_date][:month]}-#{params[:start_date][:year]} 00:00:00 CST")
      @end_date   = Time.parse("#{params[:end_date][:day]}-#{params[:end_date][:month]}-#{params[:end_date][:year]} 23:59:59 CST")

      #redbubble_order_count = Order.where(:created_at => start_date..end_date, :source_id=>5).count
      #shutterfly_order_count = Order.where(:created_at => start_date..end_date, :source_id=>6).count
      #tp_order_count = Order.where(:created_at => start_date..end_date, :source_id=>8).count
      #printswell_order_count = Order.where(:created_at => start_date..end_date, :source_id=>9).count
      #treat_order_count = Order.where(:created_at => start_date..end_date, :source_id=>12).count
      #wpd_order_count = Order.where(:created_at => start_date..end_date, :source_id=>13).count
      
      orders = Order.where(:created_at => @start_date..@end_date)

      redbubble_order_count = orders.select{|o| o.source_id==5}.count
      shutterfly_order_count = orders.select{|o| o.source_id==6}.count
      tp_order_count = orders.select{|o| o.source_id==8}.count
      printswell_order_count = orders.select{|o| o.source_id==9}.count
      treat_order_count = orders.select{|o| o.source_id==12}.count
      wpd_order_count = orders.select{|o| o.source_id==13}.count

      data_table = GoogleVisualr::DataTable.new
        data_table.new_column('string', 'Partner')
        data_table.new_column('number', 'Orders')
        data_table.add_rows(5)
        data_table.set_cell(0, 0, 'Shutterfly'     )
        data_table.set_cell(0, 1, shutterfly_order_count )
        data_table.set_cell(1, 0, 'RedBubble'      )
        data_table.set_cell(1, 1, redbubble_order_count  )
        data_table.set_cell(2, 0, 'TinyPrints'  )
        data_table.set_cell(2, 1, tp_order_count  )
        data_table.set_cell(3, 0, 'Printswell' )
        data_table.set_cell(3, 1, printswell_order_count  )
        data_table.set_cell(4, 0, 'Treat'    )
        data_table.set_cell(4, 1, treat_order_count  )
        data_table.set_cell(4, 0, 'WPD'    )
        data_table.set_cell(4, 1, wpd_order_count )
       
        opts   = { :width => 400, :height => 400, :title => 'Partner Activities', :is3D => true }
        @chart = GoogleVisualr::Interactive::PieChart.new(data_table, opts)
      end
  end
end
