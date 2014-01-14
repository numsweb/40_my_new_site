
require 'debugger' if Rails.env.devlopment?

class OrderItem < ActiveRecord::Base

  # Stores and processes items attached to orders.

  require 'fileutils'


  # Association Structure
  belongs_to :product
  belongs_to :order

  # ActiveRecord Validations
  validates_presence_of :quantity, :unit_price

  # ActiveRecord Callbacks
  before_validation(:on => :create) do set_price end
  after_create :route_for_manufacturing, :decrement_stock, :fix_price_for_vendor

  #scope :fifo,          :order => 'order_items.created_at asc'
  #scope :lifo,          :order => 'order_items.created_at desc'
  #scope :customized,    :conditions => ['orderable_type = ?', 'CustomizedDesign']
  #scope :not_approved,  :conditions => ['approved is null']
  #scope :active,        :conditions => ["orders.order_status not in (#{Order.status_codes['Cancelled']}, #{Order.status_codes['Archived']})"]
  #scope :denied,        :conditions => ['approved = 0']
  #scope :approved,      :conditions => ['approved = 1']
  #scope :not_printed,   :conditions => ['printed is null or printed = 0']
  #scope :valid_billing, :conditions => ["orders.order_status != #{Order.status_codes['Billing Error']}"], :include => :order
  #scope :fetched,       :conditions => ['asset_file_name is not null']
  #scope :product,       lambda { |*args| { :conditions => ["product_id = ?", args.first] } }
  #scope :printable,     :conditions => ['approved = 1
  #                                             and (printed is null or printed = 0)
  #                                             and printable_file_name is not null
  #                                             and (quantity_manufactured is null or quantity_manufactured < quantity)']


  attr_accessible :printable_file_name, :product_id, :quantity, :unit_price, :asset_updated_at, :orderable_id, :approved,
  :orderable_type, :asset_url, :rotation, :x_offset, :y_offset, :scale, :shipping_label, :tracking_number, :shipped, :printed

  ## Asset Attachment
  #has_attached_file :asset,
  #                  :styles => { :original => ["100%", :jpg], :preview => ["256x256", :jpg], :thumbnail => ["100x100", :jpg] },
  #                  # :source_file_options => lambda {|a| {:original => a.instance.pdf? ? '-density 300' : ''}},
  #                  :source_file_options => { :original => '-density 300' },
  #                  :url  => "/assets/products/:id_partition/:style/:basename.:extension",
  #                  :path => ":rails_root/public/assets/products/:id_partition/:style/:basename.:extension"

  ## Shipping Label Attachment
  #has_attached_file :shipping_label,
  #                  :url  => "/assets/shipping_labels/:id_partition/:style/:basename.:extension",
  #                  :path => ":rails_root/public/assets/shipping_labels/:id_partition/:style/:basename.:extension",
  #                  :styles => {:original => "100%"},
  #                  :convert_options => { :all => '-rotate 90' }
  #                  #the convert options only work if you have styles to apply them to!!!
  #
  ## iPhone Wallpaper
  #has_attached_file :wallpaper,
  #                  :styles => { :thumbnail => "100x100" },
  #                  :url  => "/assets/wallpaper/:id_partition/:style/:basename.:extension",
  #                  :path => ":rails_root/public/assets/wallpaper/:id_partition/:style/:basename.:extension"
  #

  # Decrements the stock of an item once it's successfully saved.
  def decrement_stock
    product.product_component_relationships.each do |rel|
      rel.product_component.skip_saving_attachments = true
      rel.product_component.decrement!('stock', rel.quantity)
    end

    #product.send_later(:update_stock, true)
    product.delay(:queue => "assets").update_stock(true)
  end

  def pdf?
    asset_content_type == "application/pdf"
  end

  def customized?
    orderable_type == 'CustomizedDesign'
  end

  # Sets the unit price of an order item based on the current price of its product
  def set_price
    self.product    = Product.find(orderable_id)
    self.unit_price = product.price
  end
  
  def retail_value
     if self.order.source == Source.find_by_name("RedBubble")
        17.00
     else
       self.product.price.to_f
     end
  end

  def fix_price_for_vendor
    unless self.order.uncommon_order?
      self.unit_price = 0
      self.save
    end
  end


  def generate_tracking_number(tracking)

    case self.order.source.name
      when "Kodak" then
        if self.order.shipping_method == 'International CN22'
          tracking_number = tracking
        else
          tracking_number = Kodak::KDK_UPS_CARRIER + ":" + tracking
        end
      else
        tracking_number = tracking
    end
    tracking_number

  end

  # Creates a Delayed Job for downloading and attaching an uploaded asset for this item.
  def route_for_manufacturing
    Core.log("ROUTE FOR MANUFACTURING")
    if self.orderable_type != "NonCustomizableProduct"
      self.delay(:queue => "assets").attach_asset_and_enqueue
    end
  end

  def preview_url(opts = {})
    if self.rendered_url.match(/^http[s]?:/)
      self.rendered_url
    else
      adjustments = opts.collect{|k,v| "#{k}=#{v}"}.join('&')
      "#{Core::SITE_URLS[Rails.env]}/image_cache#{self.rendered_url}?#{adjustments}"
    end
  end

  # Called by Delayed Job to download and attach an uploaded asset for an order item,
  # then enqueues the item to generate a manufacturable asset for when it's approved.
  def attach_asset_and_enqueue

    Core.log("============= RETRIEVING ASSET FOR ##{self.id}")
    begin
      design_url = URI.parse(self.asset_url)
      rand_id    = rand(999999).to_s
      tempfile   = "#{Rails.root}/tmp/" + rand_id + '.jpg'
      error_file = "#{Rails.root}/tmp/#{self.product.id}-#{self.id}-#{self.order.id}-error" + '.jpg'
      Core.log("********** Creating Tempfile #{tempfile} **************")
      tries = 0

      begin
        http = Net::HTTP.new(design_url.host, design_url.port)
        use_ssl = (design_url.port == 443) ? true : false
        http.use_ssl = use_ssl
        http.open_timeout = 15
        http.read_timeout = 30
        
        if design_url.query.blank?
          path = design_url.path
        else
          path = design_url.path + "?" + design_url.query
        end
        
        Core.log("*********** Image URL: #{self.asset_url} ****************")
        request = Net::HTTP::Get.new(path)
        response = http.request(request)
        
        if response.kind_of?(Net::HTTPRedirection)
          Core.log "============= WE GOT REDIRECTED! ====================="
          design_url = URI.parse(response['location'])
          Core.log("*********** Image URL: #{design_url} ****************")
          raise "WE_GOT_REDIRECTED"
        end

        Core.log("============= HTTP response code: #{response.code.inspect}, HTTP message: #{response.message.inspect}")
        open(tempfile, "wb") {|file| file.write(response.body)}

      rescue
        Core.log("============= In the rescue HTTP response: #{response.inspect}")
        tries += 1
        Core.log("============= RETRY NUMBER #{tries.to_s}:  ASSET RETRIEVAL FOR ##{self.id}")
        retry if tries < 3
        Core.log("============= RETRY: giving up on ASSET RETRIEVAL FOR ##{self.id}")
        Core.log("*************** Deleting Tempfile #{tempfile} ******************")
        File.delete(tempfile)
      end

      File.open(tempfile, 'rb') { |design| self.asset = design }
      asset_width   = Paperclip::Geometry.from_file(tempfile).width.to_i
      asset_height  = Paperclip::Geometry.from_file(tempfile).height.to_i

      self.asset_dimensions = "#{asset_width}x#{asset_height}"
      self.save

=begin
    if self.order.source.name.upcase == "SHUTTERFLY" || self.order.source.shutterfly_partner
        file_type = %x[identify -format '%m' "#{tempfile}"].gsub!("\n", "")
        if file_type == "PDF"
          #save a copy for jessa's color comparisons
          target = "#{Rails.root}/public/assets/uploaded_pdfs/"  + self.order.id.to_s + "-" + self.id.to_s + "-original.pdf"
          Core.log("*************** Copying Tempfile #{tempfile}  to uploaded_pdf file #{target}******************")
          FileUtils.cp(tempfile, target)
        end
      end
=end


      Core.log("*************** Deleting Tempfile #{tempfile} ******************")
      File.delete(tempfile)

      # Drop the attached asset in the queue to generate manufacturable assets.
      Core.enqueue(self)

    rescue Exception => e
      #don't move this line below self.update_attribute...causes self to change to a different object
      self.order.set_status('Asset Error(s)')
      Rails.logger.info "\n\n****=====***** image upload failed with this error: #{e.inspect} ****=====*****\n\n"
      Core.log("============= ERROR RETRIEVING ASSET FOR ##{self.id}")
      OrderStatus.create(:order_id => order.id, :status => "Error fetching asset ##{id}")
      self.update_attribute(:asset_errors, true)
      Core.log("*************** Renaming Tempfile #{tempfile} => #{error_file} ******************")
      File.rename(tempfile,error_file)
    end

  end


  # Generates 320x480 wallpaper from the customer's configured design
  # that's included in order receipts.
  def generate_wallpaper
    if self.order.uncommon_order?
      begin
        rand_id = rand(999999).to_s
        image = MiniMagick::Image.from_file("#{Rails.root}/public/assets/printable/#{printable_file_name}-1.jpg")
        image.gravity('Center')
        image.rotate(90)
        image.resize('400x600^')
        image.crop('320x480+40+120')
        image.write("#{Rails.root}/tmp/#{rand_id}.jpg")
        File.open("#{Rails.root}/tmp/#{rand_id}.jpg", 'rb') { |image| self.wallpaper = image }
        File.delete("#{Rails.root}/tmp/#{rand_id}.jpg")
        self.save
      rescue Exception => e
        UncommonHoptoad::notify("Error generating wallpaper for #{id}","Error: #{e.message}", "Failed to generate wallpaper for order_item #{self.id}")
      end
    end
  end

  # Used for stats on the Dashboard.
  # Returns the total number of order items shipped this week.
  def self.shipped_this_week
    total = 0
    Order.this_week.shipped.each { |o| total += o.order_items.size }
    total
  end

end

