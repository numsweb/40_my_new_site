# $: << "."
# require 'lib/report.rb'

class Order < ActiveRecord::Base
  #require 'fedex'
  #require 'money'
 
  # Association Structure
  has_many :notes,          :dependent => :destroy
  has_many :order_items,    :dependent => :destroy
  has_many :order_statuses, :dependent => :destroy
  has_many :addresses,      :as => :addressable, :dependent => :destroy
  has_one  :shutterfly_job_suborder
  belongs_to :shipping_method

  belongs_to :source
  belongs_to :discount
  belongs_to :kodak
  belongs_to :uncommon_job

  has_one :orders_shutterfly_job
  has_one :shutterfly_job, :through => :orders_shutterfly_job
  belongs_to :job, :polymorphic => true  # REST API or SOAP API (Kodak)
  
  

  # Nested models. Order accepts attributes for addresses and order items,
  # which are created along with the order object.  Callbacks are triggered on
  # these objects as expected when validated, saved, created, destroyed, etc.
  accepts_nested_attributes_for :addresses, :order_items
  

  # Attributes that can be passed in when placing an order.
  # These attributes are used in the initial order flow, but not saved to the database.
  attr_accessor :discount_code, :just_a_quote, :shipping_quote_hash, :grant_free_shipping,
                :cc_number, :cc_verify, :saved_credit_card
  attr_accessible :order_status, :job_id, :job_type, :account_id, :source_id, :first_name,
                :last_name, :email, :vendor, :subtotal, :shipping_price, :shipping_method_id,
                :tax, :phone, :uncommon_job_id, :ship_to_name, :completion_date, :completed_on,
                :residential_address, :fedex_address_score, :confirmed_shipping_method

  # ActiveRecord Validations
  validates_presence_of :source_id, :first_name, :last_name, :email, :addresses, :order_items
  validates_presence_of :phone, :if => :uncommon_order?                     
  validates_associated :addresses, :order_items
  validates_format_of :email, :with => /\A([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})\Z/i

  # ActiveRecord callbacks.  This defines the order processing flow.
  # When an order is received, a saved credit card is applied if necessary, the subtotal is calculated,
  # a discount code applied (if applicable), shipping is calculated, tax is added to the order, and the
  # grand total is tallied up.  The order's status is then set to "Fresh."  If we've gotten this far,
  # then we preauth the credit card (if payment is required), drop it in the queue if asset approval is
  # required or push it to the shipping desk if the order is entirely composed of limited editions.
  # Then, handle saved credit card information if we've received it, and queue up the Receipt.

  before_create :set_initial_status 
  before_create :calc_subtotal, :if => :uncommon_order?
  before_create :apply_discount, :if => :uncommon_order? 
  before_create :calc_shipping, :if => :uncommon_order? 
  before_create :apply_tax, :if => :uncommon_order? 
  before_create :calc_grand_total
  before_create :queue_for_production

  ### Named Scopes
  ##scope :shipped,     :conditions => ['order_status = ?', 4]
  ##scope :shippable,   :conditions => ['order_status = ?', 5]
  ##scope :open,        :conditions => ['order_status NOT IN (7,16,17)']
  ##scope :today,       :conditions => ['created_at > ?', Date.today]
  ##scope :this_week,   :conditions => ['orders.created_at > ?', 7.days.ago]
  ##scope :sorted,      :order      => 'created_at desc'
  ##scope :with_errors, :conditions => ['order_status IN (11,13,15)']
  ##scope :cancelled,   :conditions => ['order_status = 17']
  ##
  ##scope :shutterfly_orders, :conditions => ['source_id IN (6,8,13)']
  ##scope :confirmed_shipping, :conditions => ['confirmed_shipping_method IS NOT NULL']
  ##scope :completed_last_three_days, :conditions => ['order_status=? and updated_at > ?', 7, 3.days.ago]


  # Fields to include, exclude, and methods to be called in preparing JSON/XML API responses.
  # Keeps the controllers clean, and these might as well be defined here for use around the app anyway.
  def self.api_excepts
    [:cc_number, :risk, :order_status, :preauth]
  end
  
  def self.api_includes
    {:order_items => {}, :addresses => {}}
  end
  
  def self.api_methods
    [:status_in_words, :save_credit_card]
  end


  # Order Processing Logic ==========================================================================
  # Methods in this section implement the order processing logic described in the ActiveRecord
  # callback processing chain above. If you're looking for a method involved in processing an order,
  # it's all here.
  
  # Determines if payment is required for an order by tallying up the total cost of the order after
  # discount, tax, and shipping have been applied. If the total amount is $0.00, no payment is required.
  # Otherwise, credit card information must be supplied to process the order to be charged on fulfillment.
  def payment_required?
    order = self.dup
    order.just_a_quote = true
    order.order_items.map(&:set_price)
    order.calc_subtotal
    order.apply_discount

    order.calc_shipping(true) if order.shipping_price.blank?

    order.subtotal != 0 or order.shipping_price != 0
  end
  

  def asset_errors?
    asset_errors = false
    self.order_items.each do |item|
      asset_errors = true if item.asset_errors?
    end
    asset_errors
  end

  def uncommon_order?
    #self.source.name == "Uncommon"
    false
  end

  def red_bubble_order?
    self.source.name == "RedBubble"
  end

  def kodak_order?
    self.source.name == "Kodak"
  end

  def shutterfly_order?
    self.source.name == "Shutterfly"
  end
  
  def international_shipping?
    shipping = addresses.detect { |a| a.address_type == 'shipping' }
    if ShutterflyJob::US_TERRITORIES_ABREVIATIONS.include?(shipping.region.upcase) ||
      ShutterflyJob::US_TERRITORIES.include?(shipping.region.downcase)
        return true
    elsif (shipping.country.upcase != "UNITED STATES") && (shipping.country.upcase != "US")
      return true
    else
      return false
    end
  end
  
  def ups_shipping?
    if shipping_method.nil?
      false
    else
      ActiveMerchant::Shipping::UPS.service_code_for[shipping_method.physical].nil? ? false : true
    end
  end
  
  def fedex_shipping?
    if shipping_method.nil?
      false
    else
      Fedex::Request::Base::SERVICE_TYPES.include?(shipping_method.physical)
    end
  end

  def oz_link_sources?
    oz_link_sources = ["Shutterfly", "TinyPrints", "TP", "TREAT", "WPD", "RedBubble"]
    oz_link_sources.include?(source.name)
  end

  def oz_link_shipping?
    oz_link_ship_methods = ["UPS MI", "USPS FC", "USPS PRIORITY MAIL"]
    if shipping_method.nil?
      false
    else
      oz_link_ship_methods.include?(shipping_method.physical.upcase)
    end
  end

  # Calculate the order subtotal.
  # Sum of the unit price of each item times the quantity ordered.
  def calc_subtotal
    if self.uncommon_order?
      amount = 0
      order_items.each { |i| amount += (i.unit_price * i.quantity) }
      self.subtotal = amount
    else
      self.subtotal = 0
    end
  end

  # Applies a discount code to an order if a valid one has been provided.

  # If the discount_code param has been passed in with this order, then search for a matching valid
  # discount and apply it if the requirements are met.
  # Otherwise, if this method is applied to an existing order (which happens when an item is removed from
  # an order and the total must be recalculated), then just take the discount object already associated.
  # If a discount is found and it's not invalid, then apply it (either percent or dollar off).

  # Finally, associate the discount object with the order, set the "Free Ground Shipping" flag used by
  # used by Core#shipping_rates to set the first shipping option to "$0.00", and increment the number of
  # times this discount has been used unless we're just processing an order quote.
  def apply_discount
    if discount_code
      @discount = Discount.valid.find_by_code(discount_code)
      @invalid = true if @discount and @discount.minimum_order and (self.subtotal < @discount.minimum_order.to_f)
    elsif self.discount_id.present?
      @discount = self.discount
    end

    if @discount and not @invalid
      if @discount.discount_type == 'percent'
        self.subtotal = self.subtotal * (1 - @discount.discount/100.0)
      elsif @discount.discount_type == 'dollar'
        self.subtotal = self.subtotal - @discount.discount.to_f
      end

      self.discount_id = @discount.id
      self.grant_free_shipping = true if @discount.free_shipping
      unless just_a_quote
        @discount.increment_uses
        @discount.updated_at = Time.now
        @discount.save
      end
    end

    self.subtotal = 0 if subtotal < 0
  end
  
  # Caculate discount for order
  def csv_discount
    discount = 0.to_f
    if self.discount
      unless self.subtotal.zero?
        discount = (self.subtotal + self.tax + self.shipping_price) - self.total_price
      end
    end
    discount
  end

  # Retrieves shipping information from a previously-stored quote if applicable,
  # or fetches a new shipping quote if none exists to set the shipping cost of the order.
  # If a shipping method has been selected ("UPS Ground", "UPS 2nd Day Air", etc.), we use that.
  # If none is supplied or that method is unavailable, we default to the first option returned by UPS (Ground).
  def calc_shipping(testing_payment_required = false)
    @valid_quote = ShippingQuote.find_by_quote_hash(self.shipping_quote_hash) if self.shipping_quote_hash

    if @valid_quote
      self.shipping_price = @valid_quote.rates.detect {|i| i[0] == shipping_method }[1] rescue self.shipping_price = @valid_quote.rates[0][1]
      @valid_quote.destroy unless testing_payment_required
    else
      rates = Core.shipping_rates(self, false)
      if rates
        self.shipping_price = rates.detect {|i| i[0] == shipping_method }[1] rescue self.shipping_price = rates[0][1]
      else
        raise('Unshippable Address')
      end
    end
  end

  # Calculates and applies sales tax to an order for shipping addresses 
  # to which Uncommon is obligated to collect sales tax. Currently KY and IL.
  def apply_tax
    rate = case addresses.detect {|a| a.address_type == 'shipping' }.region
      when 'KY' then 0.06
      when 'IL' then 0.0625
      when 'CA' then 0.0725
      else 0
    end

    # Shipping N/A if this is an order quote (in which case the shipping address is blank).
    self.shipping_price = 0 if shipping_price.blank?
    self.tax = (subtotal + shipping_price) * rate
  end

  # Calculates the grand total of an order used for billing.
  # This is the sum of the subtotal, shipping price, and sales tax.
  def calc_grand_total
    unless self.uncommon_order?
      self.total_price = 0
      return
    end 
    self.total_price = self.subtotal + self.shipping_price + self.tax
    self.total_price = 0 if self.total_price < 0
    
    
    #Rails.logger.info "\n\n*** Total price is #{self.total_price.inspect}"
  end

  # Sets the status of an order to "Fresh" when received, and creates
  # an associated Order Status log entry for customer order tracking.
  def set_initial_status
    Core.log("=== SETTING INITIAL ORDER STATUS TO 'FRESH': #{id}")
    OrderStatus.create(:order_id => self.id, :status => 'Fresh')
    self.set_status('Fresh')
  end

  # Decrypts and applies a saved credit card based on a hash from the user's account.
  def apply_saved_card
    cc = CreditCard.find_by_cc_vault_id_and_account_id_and_source_id(saved_credit_card, account_id, source_id)

    raise 'Saved credit card not found.' if cc.blank?
    self.saved_credit_card, self.cc_vault_id = cc.cc_vault_id, cc.cc_vault_id
  end


  # Preauthorizes a credit card against the payment gateway, then updates the order status accordingly.
  # If preauthorization fails, then kick the order out and reply to the remote API with the failure
  # message provided by the payment gateway.
  def preauth_card
    Core.log("=== PREAUTHORIZING CREDIT CARD: #{id}")
    
    if saved_credit_card.present?
      credit_card = saved_credit_card.dup
    else
      
      exp = (cc_exp.class == Date ? cc_exp : Date.parse(cc_exp))
      
      credit_card = ActiveMerchant::Billing::CreditCard.new(
        :type               => cc_type,
        :number             => cc_number.gsub(/\D/,''),
        :verification_value => cc_verify,
        :month              => exp.month,
        :year               => exp.year,
        :first_name         => first_name,
        :last_name          => last_name
      )

      self.cc_last_four_digits = cc_number[12,16]
    end
  
    billing = addresses.detect { |a| a.address_type == 'billing' }
    raise 'No billing address supplied' if billing.nil?
    
    # TODO: Set Request IP address.
    purchase_options = {
      :ip => '127.0.0.1',
      :billing_address => {
        :name     => "#{first_name} #{last_name}",
        :address1 => "#{billing.street_1} #{billing.street_2}",
        :city     => billing.city,
        :state    => billing.region,
        :country  => billing.country,
        :zip      => billing.postal_code
      }
    }

    purchase_options.merge!({:store => true}) unless self.saved_credit_card.present?
    @response = PAYMENT_GATEWAY.authorize(self.total_price.to_money.cents, credit_card, purchase_options)
    #logger.info "RESPONSE: #{@response.inspect}"    
    if @response.success?
      self.cc_vault_id = @response.params['customer_vault_id'] unless @response.params['customer_vault_id'].blank?
      self.preauth = @response.authorization
      self.set_status('Card Approved')
      Core.log("=== CREDIT CARD PREAUTHORIZED - SETTING STATUS TO 'CARD APPROVED': #{id}")
      OrderStatus.create(:order_id => self.id, :status => 'Card Approved')
    else
      logger.info "=== CREDIT CARD DECLINED: #{id}"
      raise 'Credit card declined.  ' + @response.params["responsetext"]
    end

  end
  

  # If the order does not consist solely of Limited Editions, mark
  # the status as "Asset Approval Pending". Otherwise, set the status to Assets Approved.
  # (If the status is not Card Approved at this point, there was a billing or data error)
  def queue_for_production
    if !self.uncommon_order? and self.order_items.detect { |i| !i.approved }
      Core.log("=== SETTING KODAK ORDER STATUS TO APPROVAL PENDING: #{id}")
      self.set_status('Asset Approval Pending')
      OrderStatus.create(:order_id => self.id, :status => 'Asset Approval Pending')
    
    elsif (self.status_in_words == 'Card Approved' or self.total_price.to_money.to_s == '0.00') and self.order_items.detect { |i| !i.approved }
      Core.log("=== SETTING ORDER STATUS TO APPROVAL PENDING: #{id}")
      self.set_status('Asset Approval Pending')
      OrderStatus.create(:order_id => self.id, :status => 'Asset Approval Pending')

    elsif self.status_in_words == 'Card Approved' or self.total_price.to_money.to_s == '0.00'
      if self.order_items.detect{|i| i.orderable_type == "NonCustomizableProduct"} && self.order_items.select{|i| i.orderable_type == "NonCustomizableProduct"}.length == self.order_items.length
        Core.log("=== SETTING ORDER STATUS TO READY TO SHIP: #{id}")
        self.set_status('Ready to Ship')        
      else
        Core.log("=== SETTING ORDER STATUS TO ASSETS APPROVED: #{id}")
        self.set_status('Asset(s) Approved')
        OrderStatus.create(:order_id => self.id, :status => 'Pre-made case assets auto-approved; item queued for manufacturing.')
      end
    end
  end
  

  # Encrypts the credit card details and returns a hash of the card
  # information if the user has requested their details be saved.
  def handle_vaulted_card
    #== The user has requested their card details be saved, and has no card saved currently.
    if save_credit_card and self.saved_credit_card.blank?
      saved_credit_card = CreditCard.create(:account_id => account_id, :source_id => source_id, :cc_vault_id => cc_vault_id)

    #== The user has requested their card details be saved, and has a card stored that should be updated.
    elsif save_credit_card and self.saved_credit_card and self.cc_number
      cc = CreditCard.find_by_cc_vault_id_and_account_id_and_source_id(self.saved_credit_card, account_id, source_id)

      credit_card = ActiveMerchant::Billing::CreditCard.new(
        :type               => cc_type,
        :number             => cc_number.gsub(/\D/,''),
        :verification_value => cc_verify,
        :month              => Date.parse(cc_exp).month,
        :year               => Date.parse(cc_exp).year,
        :first_name         => first_name,
        :last_name          => last_name
      )
      @response = PAYMENT_GATEWAY.update(cc_vault_id, credit_card)
      
      unless @response.success?
        @response = PAYMENT_GATEWAY.store(cc_vault_id, credit_card) 
        self.cc_vault_id = @response.params['customer_vault_id']
      end
      
      CreditCard.create({:account_id => account_id, :source_id => source_id, :card_type => cc_type, :cc_vault_id => cc_vault_id}) if cc.blank?

    #== The user has a credit card currently saved, but wishes to delete it after processing this order.
    elsif self.saved_credit_card and not save_credit_card
      CreditCard.find_by_cc_vault_id_and_account_id_and_source_id(self.saved_credit_card, account_id, source_id).destroy rescue nil
    end
  end
  
  
  # Charges the customer for the order once all items in the order
  # have been picked / manufactured and shipped successfully.
  def capture_funds
    if order_items.detect { |item| item.shipped < item.quantity }
      self.set_status('Partially Fulfilled')
    else
      if self.cc_vault_id.present?
        self.charge_card unless self.paid
      else
        OrderStatus.create(:order_id => self.id, :status => 'Order complete.')
        self.update_attributes({:completed_on => Time.now})
        self.set_status('Complete')
      end
    end
  end
    
    
  # Captures the funds from the customer's credit card once all items
  # in the order have been shipped using the preauthorization we have.
  def charge_card
    Core.log("Charging card for Order ##{id} for #{total_price.to_money.cents.to_i} cents")
    begin
      result = PAYMENT_GATEWAY.capture(total_price.to_money.cents.to_i, preauth)

      if result.success?
        OrderStatus.create(:order_id => self.id, :status => 'Attempted to capture funds from credit card')
        OrderStatus.create(:order_id => id, :status => "Order status set to Complete: #{result.message}")
        self.update_attributes({ :paid => true, :completed_on => Time.now })
        PAYMENT_GATEWAY.delete(self.cc_vault_id) unless self.save_credit_card
        self.set_status('Complete')
        
      else
        # Expired preauth or invalid billing information. Attempt to purchase directly.
        OrderStatus.create(:order_id => self.id, :status => 'Preauth capture attempt failed; attempting to capture directly from credit card')

        billing = addresses.detect { |a| a.address_type == 'billing' }
        purchase_options = {
          :ip => '127.0.0.1',
          :billing_address => {
            :name     => "#{first_name} #{last_name}",
            :address1 => "#{billing.street_1} #{billing.street_2}",
            :city     => billing.city,
            :state    => billing.region,
            :country  => billing.country,
            :zip      => billing.postal_code
          }
        }
        result = PAYMENT_GATEWAY.purchase(total_price.to_money.cents.to_i, cc_vault_id, purchase_options)

        if result.success?
          OrderStatus.create(:order_id => id, :status => "Order status set to Complete: #{result.message}")
          self.update_attributes({ :paid => true, :completed_on => Time.now })
          PAYMENT_GATEWAY.delete(self.cc_vault_id) unless self.save_credit_card
          self.set_status('Complete')
        else
          self.set_status('Billing Error')
          OrderStatus.create(:order_id => self.id, :status => 'Attempted to capture funds from credit card')
          OrderStatus.create(:order_id => id, :status => "Billing failed with message: #{result.message}")
        end
        
      end
    rescue Exception => e
      self.set_status('Billing Error')
      OrderStatus.create(:order_id => self.id, :status => 'Attempted to capture funds directly from credit card')
      OrderStatus.create(:order_id => id, :status => "Billing failed with message: #{e.message}")
    end
  end
  
  
  # Updates the status of an order after an asset is moderated
  # If an item has been rejected, set the order status to "asset error."
  # If no assets requiring approval remain, update the status to "printing."
  def update_status_after_moderation
    if order_items.customized.detect { |item| item.approved == false }
      Core.log("=== SETTING ORDER STATUS TO REJECTED: #{id}")
      set_status('Asset(s) Rejected')
      OrderStatus.create(:order_id => id, :status => 'Asset(s) Rejected')
    elsif !order_items.customized.detect { |item| item.approved.nil? }
      if self.order_items.detect{|i| i.orderable_type == "NonCustomizableProduct"} && self.order_items.select{|i| i.orderable_type == "NonCustomizableProduct"}.length == self.order_items.length
        Core.log("=== SETTING ORDER STATUS TO READY TO SHIP: #{id}")
        self.set_status('Ready to Ship')        
      else
        Core.log("=== SETTING ORDER STATUS TO ASSETS APPROVED: #{id}")
        self.set_status('Asset(s) Approved')
        OrderStatus.create(:order_id => self.id, :status => 'Asset(s) Approved')
      end
    end
  end
  
  
  # Updates the status of an order after an item in it has shipped.
  # This method is called automatically when an item ships, but can be called by an admin
  # if the Order Status is set manually from the Order detail page.
  
  # If everything has shipped, charge the customer if they've not already been billed
  # and send them a confirmation e-mail.
  def update_status_after_shipping(manual = false)
    Core.log("========== Updated status after shipping")
    if not manual and order_items.detect { |item| item.shipped < item.quantity }
      self.set_status('Partially Fulfilled')
    else
      if manual
        self.order_items.each { |item| item.update_attributes({:shipped => item.quantity}) }
        #this is the manual path to mark as shipped   
      else
        #this is the automatic update of the order to shipped
        update_attributes(:order_status => Order.status_codes['Shipped'])
        OrderStatus.create(:order_id => self.id, :status => 'All items shipped')
      end
      update_attributes(:completion_date => Time.now()) #datestamp the completion 
      self.capture_funds
    end
  end  


  # Returns a quote for an order showing the total amount to
  # be charged following the application of a discount code and a
  # series of shipping options + estimates based on items ordered.
  def self.prepare_quote(params)
    order = Order.new(params.dup.merge(:just_a_quote => true))
    prep_item = [:set_price]
    prep_order = [:calc_subtotal, :apply_discount, :apply_tax]

    order.order_items.each { |oi| prep_item.each { |m| oi.send(m) } }
    prep_order.each { |method| order.send(method) }
    Core.log("========== CALLING FIND_RATES FOR THIS ORDER #{order.inspect}")
    
    shipping_rates, errors = Core.shipping_rates(order, true)
    { :shipping_rates => shipping_rates, :tax => order.tax.to_money.to_s, :subtotal => order.subtotal.to_money.to_s, :errors => errors }
  end
  
  
  # Order status codes used throughout the application.
  def self.status_codes
    {'Fresh'                  => 0, 
     'Card Approved'          => 1,
     'Asset Approval Pending' => 2,
     'Asset(s) Approved'      => 3,
     'Printing'               => 4,
     'Ready to Ship'          => 5,
     'Shipped'                => 6,
     'Complete'               => 7,
     'Partially Fulfilled'    => 8,
     'Billing Error'          => 11,
     'Asset(s) Rejected'      => 12,
     'Asset Error(s)'         => 13,
     'Shipping Error'         => 15,
     'Archived'               => 16,
     'Cancelled'              => 17}
  end
  
  
  # Updates the status of an order.
  # Acts a bit like a state machine in that can call methods on specific transitions.
  # This method is normally called automatically, but can be manually triggered if an
  # administrator uses the "Manually Update Order Status" function in the Order Detail view.
  def set_status(transition_to, manual = false)
    new_record? ? self.order_status = Order.status_codes[transition_to] : update_attributes(:order_status => Order.status_codes[transition_to])
    OrderStatus.create({:order_id => self.id, :status => "Order status manually changed to '#{transition_to}'"}) if manual

    case transition_to
      when 'Shipped'            then
                                  self.update_status_after_shipping(true)
      when 'Cancelled'          then
                                   if self.job_id? # Is this a REST API (Red Bubble, etc.) or SOAP (Kodak) Job?
                                     #self.job.send_later(:send_job_rejected_response, "The order was cancelled.")
                                     self.job.delay(:queue => "assets").send_job_rejected_response("The order was cancelled.")
                                     OrderStatus.create(:order_id => self.id, :status => "Sent Job Rejected, CANCELLED for order:  ##{self.id.to_s}, Source: #{self.source.name} Vendor Order: #{job.get_vendor_order_id}")
                                   end
                                   
      when 'Billing Error'      then
                                  if self.uncommon_order?
                                  end        

      when 'Asset(s) Rejected'  then
                                  if self.job_id? # Is this a REST API (Red Bubble, etc.) or SOAP (Kodak) Job?
                                    #self.job.send_later(:send_job_rejected_response, "Terms of Service")
                                    self.job.delay(:queue => "assets").send_job_rejected_response("Terms of Service")
                                    OrderStatus.create(:order_id => self.id, :status => "Sent Job Rejected, ASSETS REJECTED,  for order:  ##{self.id.to_s}, Source: #{self.source.name} Vendor Order: #{job.get_vendor_order_id}")
                                  end
                                  
      when 'Asset Error(s)'     then 
                                  if self.job_id? # Is this a REST API (Red Bubble, etc.) or SOAP (Kodak) Job?
                                    unless self.asset_errors? #this is so the we only send ONE message back
                                      if self.vendor == "Kodak" #Kodak wants a notify  message unless Uncommon is giving up on the order
                                        #self.job.send_later(:send_job_notify_response, "Asset Errors")
                                        self.job.delay(:queue => "assets").send_job_notify_response("Asset Errors")
                                      else
                                        #self.job.send_later(:send_job_rejected_response, "Asset Errors")
                                        self.job.delay(:queue => "assets").send_job_rejected_response("Asset Errors")
                                      end
                                      OrderStatus.create(:order_id => self.id, :status => "Sent Job Rejected, ASSET ERRORS,  for order:  ##{self.id.to_s}, Source: #{self.source.name} Vendor Order: #{job.get_vendor_order_id}")
                                    end
                                  end

      when 'Complete'           then
                                  self.update_attribute(:completion_date, Time.now())
                                  if self.job_id? # Is this a REST API (Red Bubble, etc.) or SOAP (Kodak) Job?
                                    #self.job.send_later(:send_job_shipped_response)
                                    self.job.delay(:queue => "assets").send_job_shipped_response
                                    OrderStatus.create(:order_id => self.id, :status => "Sent Job Shipped Response for order:  ##{self.id.to_s}, Source: #{self.source.name} Vendor Order: #{job.get_vendor_order_id}")
                                  end

      else nil
    end

  end


  # Blanks out credit card information after an order has been successfully processed.
  # This method is called by a cron job that runs nightly.  Card numbers are blanked out
  # two weeks after the order has shipped and is marked Complete in order to provide lead
  # time for customer service in the event that the quality is not up to par.
  def blank_out_credit_card
    num = (self.cc_number[0] == 'x' ? self.cc_number : "xxxx-xxxx-xxxx-#{cc_number[12,16]}")
    self.update_attributes({:cc_number => num})
  end

  # END ORDER PROCESSING LOGIC =============================================================================
  

  #special additions for Shutterfly schema
  def shutterfly_job_uncommon_orders
    #find all the orders that came from the shutterfly_job
     if shutterfly_affiliate_order?
      job = self.job.shutterfly_job
      orders = []
      job.shutterfly_job_suborders.each do |sub|
        orders << sub.order
      end
      orders
    else
      orders = []
    end
    orders
  end
  
  def shutterfly_job_uncommon_orders_ids
    #find all the orders that came from the shutterfly_job
     if shutterfly_affiliate_order?
      job = self.job.shutterfly_job
      orders = []
      job.shutterfly_job_suborders.each do |sub|
        orders << sub.order.id
      end
      if orders.size > 1
        orders = orders.join(", ")
      else
        orders = orders[0].to_s
      end
    else
      orders = ""
    end
    orders
  end
  
  def shutterfly_order?
    self.source.shutterfly_partner
  end
  
  
  def shutterfly_job_order_complete?
    if shutterfly_affiliate_order?
      orders = self.shutterfly_job_uncommon_orders
      complete = true
      orders.each do |order|
        unless order.status_in_words == "Shipped"
          complete = false
        end
      end
      complete
    else
      false
    end
  end
  
  def shutterfly_job_id
    if shutterfly_affiliate_order?
      suborder = self.job
      return suborder.shutterfly_job.id
    else
      return nil
    end
  end
  
  #def shutterfly_job
  #  if self.source.name == "Shutterfly"
  #    suborder = self.job
  #    return suborder.shutterfly_job
  #  else
  #    return nil
  #  end
  #end
  #
  
  def shutterfly_affiliate_order?
    self.source.shutterfly_partner
  end
  
  def shutterfly_order_number
    if shutterfly_affiliate_order? || self.source.name == "Shutterfly"
      suborder = self.job
      unless suborder.blank?
        job=suborder.shutterfly_job
        return job.order_number
      else
        return nil
      end
    else
      return nil
    end
  end
  
  def shutterfly_ship_method
    parts = self.shipping_method.split(" ")
    size = parts.size
    count = 1
    method = ""
    while count < (parts.size)
      method << parts[count] + " "
      count += 1
    end
    method.chop!
    ShutterflyJob::shutterfly_shipping_methods[method.downcase]
  end


  # Display Sugar =======================================
  
  def display_shipping_method
    shipping_method_id.nil? ? shipping_method_name : shipping_method.physical
  end
  
  def vendor_order_number

    if self.vendor == "Kodak"
      self.kodak.job_id
    elsif self.uncommon_job_id?
      self.uncommon_job.vendor_job_id
    elsif self.shutterfly_affiliate_order? || self.source.name == "Shutterfly"
      unless self.shutterfly_order_number.nil?
        order = self.shutterfly_order_number.to_s
      else
        order = ""
      end
      unless self.job.nil? || self.job.suborder_number.nil?
        suborder = self.job.suborder_number
      else
        suborder = ""
      end
      order + " suborder: " + suborder
    end
  end
  


  def shipping_address
    addresses.detect { |a| a.address_type == 'shipping' }
  end

  def billing_address
    addresses.detect { |a| a.address_type == 'billing' }
  end

  def customer_name
    "#{first_name} #{last_name}"
  end

  def status_in_words
    Order.status_codes.detect { |s| s[1] == order_status }[0]
  end

  # Setup UPS API based on the vender name
  def fedex_api
    # We use .first because where returns an array
    fedex_setting = self.source.fedex
    Fedex::Shipment.new(:key => fedex_setting.key,
                        :password => fedex_setting.password,
                        :account_number => fedex_setting.account_number,
                        :meter => fedex_setting.meter,
                        :mode => Rails.env.production? ? 'production' : 'development')

  end

  # Setup UPS API based on the vender name
  def ups_api
   # Core::UPS_API[self.source.name.to_sym]
   ups_setting = UpsSetting.find_by_source_id(self.source.id)
   ActiveMerchant::Shipping::UPS.new( :login => ups_setting.login,
                               :password => ups_setting.password,
                               :key => ups_setting.key)
  end

  # Setup UPS ORIGIN based on the vender name
  def ups_origin
    #Core::UPS_ORIGIN[self.source.name.to_sym]
    ups_setting = UpsSetting.find_by_source_id(self.source.id)
    ActiveMerchant::Shipping::Location.new(:name => ups_setting.name,
                  :company_name => ups_setting.origin_company_name,
                  :attention => ups_setting.origin_attention,
                  :address1 => ups_setting.origin_address1,
                  :address2 => ups_setting.origin_address2,
                  :city => ups_setting.origin_city,
                  :address_type => ups_setting.origin_address_type,
                  :state => ups_setting.origin_state,
                  :zip => ups_setting.origin_zip,
                  :country => ups_setting.origin_country,
                  :phone => ups_setting.origin_phone,
                  :number => ups_setting.origin_number)
  end

  # Setup UPS SHIPPER based on the vender type
  def ups_shipper
    ups_setting = UpsSetting.find_by_source_id(self.source.id )
    return nil if ups_setting.blank? #so we can still display Uncommon orders, like we need to!
    ActiveMerchant::Shipping::Location.new(:name => ups_setting.shipper_name,
                  :company_name => ups_setting.shipper_company_name,
                  :attention => ups_setting.shipper_attention,
                  :address1 => ups_setting.shipper_address1,
                  :address2 => ups_setting.shipper_address2,
                  :city => ups_setting.shipper_city,
                  :address_type => ups_setting.shipper_address_type,
                  :state => ups_setting.shipper_state,
                  :zip => ups_setting.shipper_zip,
                  :country => ups_setting.shipper_country,
                  :phone => ups_setting.shipper_phone,
                  :number => ups_setting.shipper_number)
  end

  def fedex_shipper
    fedex_setting = FedexSetting.where(:source_id => self.source.id, :mode => Rails.env).first
    return nil if fedex_setting.blank? #so we can still display Uncommon orders, like we need to!
    ActiveMerchant::Shipping::Location.new(:name => fedex_setting.shipper_name,
                  :company_name => fedex_setting.shipper_company_name,
                  :address1 => fedex_setting.shipper_address1,
                  :address2 => fedex_setting.shipper_address2,
                  :city => fedex_setting.shipper_city,
                  :state => fedex_setting.shipper_state,
                  :zip => fedex_setting.shipper_zip,
                  :country => fedex_setting.shipper_country,
                  :phone => fedex_setting.shipper_phone)
  end

  def usps_shipper
    # We are going to use the FEDEX shipper setting shipper address for now for USPS
    usps_setting = UspsSetting.where(:source_id => self.source.id, :mode => Rails.env).first
    return nil if usps_setting.blank? #so we can still display Uncommon orders, like we need to!
    ActiveMerchant::Shipping::Location.new(:name => usps_setting.shipper_name,
                  :company_name => usps_setting.shipper_company_name,
                  :address1 => usps_setting.shipper_address1,
                  :address2 => usps_setting.shipper_address2,
                  :city => usps_setting.shipper_city,
                  :state => usps_setting.shipper_state,
                  :zip => usps_setting.shipper_zip,
                  :country => usps_setting.shipper_country,
                  :phone => usps_setting.shipper_phone)
  end
  
  def tracking_numbers
    trackings = []
    order_items.each do |oi|
        trackings << oi.tracking_number unless oi.tracking_number.blank?
    end
    trackings.map{|tracking_number| "#{tracking_number}"}.join(", ")
  end
  
  # For Dashboard View ==================================
  def self.revenue_today
    total = 0.to_money
    Order.today.each { |order| total += order.subtotal }
    total
  end

  # Returns the top performing API based on number of orders.
  def self.top_source_this_week
    max = { :source => 'N/A', :amount => 0 }

    Source.all.each do |source|
      this_source = Order.this_week.find_all_by_source_id(source)
      max = { :source => source.name, :amount => this_source.size } if this_source.size > max[:amount]
    end

    max
  end

  # Counts the number of orders with a particular status code used in the orders/index view.
  def self.count_by_status(status)
    case status
      when 'all'              then Order.count()
      when 'open'             then Order.count(:conditions => ["order_status != #{Order.status_codes['Complete']}"])
      when 'closed'           then Order.count(:conditions => ["order_status = #{Order.status_codes['Complete']}"])
      when 'fresh'            then Order.count(:conditions => ["order_status = #{Order.status_codes['Fresh']}"])
      when 'card_approved'    then Order.count(:conditions => ["order_status = #{Order.status_codes['Card Approved']}"])
      when 'approval_pending' then Order.count(:conditions => ["order_status = #{Order.status_codes['Asset Approval Pending']}"])
      when 'approved'         then Order.count(:conditions => ["order_status = #{Order.status_codes['Asset(s) Approved']}"])
      when 'printing'         then Order.count(:conditions => ["order_status = #{Order.status_codes['Printing']}"])
      when 'shippable'        then Order.count(:conditions => ["order_status = #{Order.status_codes['Ready to Ship']}"])
      when 'partial'          then Order.count(:conditions => ["order_status = #{Order.status_codes['Partially Fulfilled']}"])
      when 'billing_error'    then Order.count(:conditions => ["order_status = #{Order.status_codes['Billing Error']}"])
      when 'asset_rejected'   then Order.count(:conditions => ["order_status = #{Order.status_codes['Asset(s) Rejected']}"])
      when 'asset_error'      then Order.count(:conditions => ["order_status = #{Order.status_codes['Asset Error(s)']}"])
      when 'shipping_error'   then Order.count(:conditions => ["order_status = #{Order.status_codes['Shipping Error']}"])
      when 'archived'         then Order.count(:conditions => ["order_status = #{Order.status_codes['Archived']}"])
      when 'cancelled'        then Order.count(:conditions => ["order_status = #{Order.status_codes['Cancelled']}"])
    end
  end
    
  # Prepares the query used by the Index action of the orders controller based on a pile of parameters.
  def self.prepare_query(params)
    field = params[:sort] ? params[:sort] : 'orders.created_at'
    order = params[:reverse] ? ' asc' : ' desc'
    params[:order_status] ||= 'open'

    unless params[:query].nil?
      #if there is a search query, we need to build the query using the sphinx syntax
      order_status = case params[:order_status]
          when 'all'              then ""
          when 'open'             then "@(order_status) !#{Order.status_codes['Complete']} & @(order_status) !#{Order.status_codes['Cancelled']} & @(order_status) !#{Order.status_codes['Archived']} & @(order_status) !#{Order.status_codes['Asset(s) Rejected']}"
          when 'closed'           then "@(order_status) = #{Order.status_codes['Complete']}"
          when 'fresh'            then "@(order_status)  = #{Order.status_codes['Fresh']}"
          when 'card_approved'    then "@(order_status)  = #{Order.status_codes['Card Approved']}"
          when 'approval_pending' then "@(order_status)  = #{Order.status_codes['Asset Approval Pending']}"
          when 'approved'         then "@(order_status)  = #{Order.status_codes['Asset(s) Approved']}"
          when 'printing'         then "@(order_status)  = #{Order.status_codes['Printing']}"
          when 'shippable'        then "@(order_status)  = #{Order.status_codes['Ready to Ship']}"
          when 'partial'          then "@(order_status)  = #{Order.status_codes['Partially Fulfilled']}"
          when 'billing_error'    then "@(order_status)  = #{Order.status_codes['Billing Error']}"
          when 'asset_rejected'   then "@(order_status)  = #{Order.status_codes['Asset(s) Rejected']}"
          when 'asset_error'      then "@(order_status)  = #{Order.status_codes['Asset Error(s)']}"
          when 'shipping_error'   then "@(order_status)  = #{Order.status_codes['Shipping Error']}"
          when 'archived'         then "@(order_status)  = #{Order.status_codes['Archived']}"
          when 'cancelled'        then "@(order_status)  = #{Order.status_codes['Cancelled']}"
        end
    else
      #we will just generate conditions for the rails "Orders.where"
      order_status = case params[:order_status]
          when 'all'              then ""
          when 'open'             then " and order_status != #{Order.status_codes['Complete']} and order_status != #{Order.status_codes['Cancelled']} and order_status != #{Order.status_codes['Archived']} and order_status != #{Order.status_codes['Asset(s) Rejected']}"
          when 'closed'           then " and order_status = #{Order.status_codes['Complete']}"
          when 'fresh'            then " and order_status = #{Order.status_codes['Fresh']}"
          when 'card_approved'    then " and order_status = #{Order.status_codes['Card Approved']}"
          when 'approval_pending' then " and order_status = #{Order.status_codes['Asset Approval Pending']}"
          when 'approved'         then " and order_status = #{Order.status_codes['Asset(s) Approved']}"
          when 'printing'         then " and order_status = #{Order.status_codes['Printing']}"
          when 'shippable'        then " and order_status = #{Order.status_codes['Ready to Ship']}"
          when 'partial'          then " and order_status = #{Order.status_codes['Partially Fulfilled']}"
          when 'billing_error'    then " and order_status = #{Order.status_codes['Billing Error']}"
          when 'asset_rejected'   then " and order_status = #{Order.status_codes['Asset(s) Rejected']}"
          when 'asset_error'      then " and order_status = #{Order.status_codes['Asset Error(s)']}"
          when 'shipping_error'   then " and order_status = #{Order.status_codes['Shipping Error']}"
          when 'archived'         then " and order_status = #{Order.status_codes['Archived']}"
          when 'cancelled'        then " and order_status = #{Order.status_codes['Cancelled']}"
      end
    end
    
    payment_status = case params[:payment_status]
      when 'paid'       then " and order_status = #{Order.status_codes['Complete']}"
      when 'authorized' then ' and (order_status > 0 and order_status != 11)'
      when 'error'      then ' and order_status = 11'
      else ''
    end
    
    shipping_status = case params[:shipping_status]
      when 'shipped'    then " and order_status in (#{Order.status_codes['Shipped']}, #{Order.status_codes['Complete']})"
      when 'partial'    then " and order_status = #{Order.status_codes['Partially Fulfilled']}"
      when 'unshipped'  then " and order_status not in (#{Order.status_codes['Shipped']}, #{Order.status_codes['Complete']})"
      else ''
    end


    unless params[:query]
      conditions = ["1 = 1 #{order_status} #{payment_status} #{shipping_status}"]
    end


    field = params[:sort]
    if field.blank?
      field = "id"
    end
       
    { :field => field, :order => order, :conditions => conditions, :search => params[:query], :order_status => order_status}

  end

  # Generates a CSV dump of all orders in the database.
  def self.csv_export(orders)
    orders_report(orders)
  end
  
  def self.change_shutterfly_shipping_methods(path, shipping_methods_import_id)
    import = ChangeShippingMethodsImport.find_by_id(shipping_methods_import_id)
    import.update_attribute("status", "processing")
    begin
      require 'roo'
      file_ext = path.split(".")[1]
      begin
        if file_ext.downcase == "xls"
          xl = Excel.new(path)
        elsif file_ext.downcase == "xlsx"
          xl = Excelx.new(path)
        else
          Core.log "\n\n======== Delayed Job Shipping Method Change job had this ERROR: Unknown file extension: #{file_ext}!\n\n"
          import.update_attributes(:status => "failed", :processing_errors => "Unknown file extension: #{file_ext}")
          raise "Unknown file extension: #{file_ext}"
        end
      rescue Exception => e
        Core.log "\n\n======== Delayed Job Shipping Method Change job had this ERROR: The Excel file could not be opened: #{e.message}!\n\n"
        import.update_attributes(:status => "failed", :processing_errors => "The Excel file could not be opened: #{e.message}!")
      end
      
      errors = []
      order_counter = 0
      xl.default_sheet = xl.sheets.first
      2.upto(xl.last_row) do |line|
        vendor =  xl.cell(line, 'A').lstrip.rstrip
        vendor_order_id = xl.cell(line, 'B').lstrip.rstrip
        current_method = xl.cell(line, 'C')
        new_method = xl.cell(line, 'D').lstrip.rstrip
        source = Source.find_by_name(vendor)

        unless source.blank? 
          if source.shutterfly_partner == true
            sj = ShutterflyJob.find_by_order_number(vendor_order_id)
            if sj.blank?
               errors << "ShutterflyJob not found: #{vendor} : #{vendor_order_id}"
            else
              sj.shutterfly_job_suborders.each do |suborder|
                suborder.shipping_method = new_method
                source = Source.find(sj.source_id)
                shipping_method_id,residential, score = source.get_shipping_method(source, suborder)
                if shipping_method_id.kind_of?(Integer)
                  suborder.order.shipping_method_id = shipping_method_id
                end
                suborder.order.save
                suborder.save
              end
              order_counter += 1
            end
          else
           
            uj = UncommonJob.find_by_vendor_job_id(vendor_order_id)
            if uj.blank?
              errors << "UncommonJob not found: #{vendor} : #{vendor_order_id}"
            else
              uj.shipping_commitment = new_method
              uj.save
              order = uj.order
              shipping_method_id,residential, score  = source.get_shipping_method(source, uj)
              if shipping_method_id.kind_of?(Integer)
                order.shipping_method_id = shipping_method_id
              end
              order.save
              order_counter += 1
            end
          end
        else
          errors << "Source not found: #{vendor}"
        end
      end
      
      if errors.blank?
        Core.log "\n\n======== Delayed Job Shipping Method Change job processed #{order_counter.to_s} orders.}\n\n"
        import.update_attributes(:status => "finished", :successful_count => order_counter)
      else
        Core.log "\n\n======== Delayed Job Shipping Method Change job processed #{order_counter.to_s} orders.}\n\n"
        import.update_attributes(:status => "failed", :successful_count => order_counter, :processing_errors => errors)
      end

    rescue Exception => e
      import.update_attributes(:status => "failed", :processing_errors => e.message)
      Core.log "\n\n======== Delayed Job Shipping Method Change job had this ERROR: #{e.message}\n\n"
    end
  end
  
  def self.sanitize_orders(order)
    # f = File.open("orders.dump", "w+")
    # f.write(Marshal.dump(orders))
    # f.close
    # orders.each do |order|
    #   order["first_name"] = order["first_name"].force_encoding("ASCII")
    #   order["last_name"] = order["last_name"].force_encoding("ASCII")
    #   order["ship_to_name"] = order["ship_to_name"].force_encoding("ASCII")
    # end
    return order
  end

  def last_unshipped_item?
    return true if self.order_items.count == 1
    self.order_items.select { |c| c.shipped == c.quantity }.count == self.order_items.count - 1 
  end
  
  def self.export_csv(start_t, end_t, order, email_address)
    source_ids = order[:source].blank? ? Source.all.collect { |s| s.id } : Source.find_by_name(order[:source])
    status     = order[:type]

    if order[:type].empty?
      #find_in_batches
      orders = Order.where(:created_at => start_t..end_t,
                           :source_id => source_ids)
    elsif order[:type]
      orders = Order.where(:created_at => start_t..end_t,
                            :source_id => source_ids, :order_status => status)
    end
    Dir.mkdir("#{Rails.root}/data_files") unless Dir.exist? "#{Rails.root}/data_files"
    folder = "#{Rails.root}/data_files/"
    filename = "orders_#{start_t.strftime("%b-%d-%Y")}-#{end_t.strftime("%b-%d-%Y")}.csv"
    begin
    
      CSV.open(folder+filename, "wb") do |csv|
          csv << ["Id",
                  "Vendor Order Number",
                  "First Name",
                  "Last Name",
                  "E-mail",
                  "Phone",
                  "Created At", 
                  "Subtotal",
                  "Tax",
                  "Shipping Price",
                  "Shipping Method",
                  "Total Price",
                  "Source",
                  "Completion Date",
                  "Discount Code",
                  "Discount Discount Type",
                  "Discount Discount",
                  "Discount Amount", 
                  "Billing Address Street 1",
                  "Billing Address Street 2",
                  "Billing Address City",
                  "Billing Address Region",
                  "Billing Address Postal Code",
                  "Billing Address Country", 
                  "Shipping Address Street 1",
                  "Shipping Address Street 2",
                  "Shipping Address City",
                  "Shipping Address Region",
                  "Shipping Address Postal Code",
                  "Shipping Address Country",
                  "Order Item Tracking Number", 
                  "Order Item Quantity",
                  "Order Item Unit Price",
                  "Order Item Artwork",
                  "Order Item Artwork Name",
                  "Order Item Artist",
                  "Order Item Artist Name",
                  "Order Item Total",
                  "Order Item Title"]
          orders.find_each do |order|
            header = true
            vendor_order_number = ""
            if order.kodak_order?
              begin
                vendor_order_number = order.job.customer_facing_order_id
              rescue
                vendor_order_number = "UNKNOWN KODAK VENDOR ORDER NUMBER FOR Uncommon ORDER #{order.id.to_s}"
              end
            elsif order.shutterfly_order?
              begin
                vendor_order_number = order.shutterfly_job.order_number
              rescue
                vendor_order_number = "UNKNOWN SHUTTERFLY ORDER NUMBER FOR Uncommon ORDER #{order.id.to_s}"
              end
            elsif order.vendor == "RedBubble"
              begin
                vendor_order_number = order.job.vendor_order_id
              rescue
                vendor_order_number = "Unknown REDBUBBLE VENDOR ORDER NUMBER FOR Uncommon ORDER #{order.id.to_s}"
              end
            end
            
            if order.completion_date.blank?
              completion_date = ""
            else
              completion_date = order.completion_date.strftime("%m/%d/%Y")
            end
            
            
            order.order_items.each do |order_item|
              
              
              csv << [order.id,
                      header ? vendor_order_number : "", 
                      header ? order.first_name : "",
                      header ? order.last_name : "",
                      header ? order.email : "",
                      header ? order.phone : "",
                      header ? order.created_at.strftime("%m/%d/%Y %H:%M:%S") : "",
                      header ? order.subtotal.to_f : "",
                      header ? order.tax.to_f : "",
                      header ? order.shipping_price.to_f : "",
                      header ? order.display_shipping_method : "",
                      header ? order.total_price.to_f : "",
                      header ? order.source.name : "",
                      header ? completion_date : "",
                      header ? order.discount&&order.discount.code : "",
                      header ? order.discount&&order.discount.discount_type : "",
                      header ? order.discount&&order.discount.discount.to_f : "",
                      header ? order.csv_discount : "",
                      header ? order.billing_address&&order.billing_address.street_1&&order.billing_address.street_1.to_s||"" : "",
                      header ? order.billing_address&&order.billing_address.street_2&&order.billing_address.street_2.to_s||"" : "",
                      header ? order.billing_address&&order.billing_address.city||"" : "",
                      header ? order.billing_address&&order.billing_address.region||"" : "",
                      header ? order.billing_address&&order.billing_address.postal_code||"" : "",
                      header ? order.billing_address&&order.billing_address.country||"" : "", 
                      header ? order.shipping_address&&order.shipping_address.street_1&&order.shipping_address.street_1.to_s||"" : "",
                      header ? order.shipping_address&&order.shipping_address.street_2&&order.shipping_address.street_2.to_s||"" : "",
                      header ? order.shipping_address&&order.shipping_address.city||"" : "",
                      header ? order.shipping_address&&order.shipping_address.region||"" : "",
                      header ? order.shipping_address&&order.shipping_address.postal_code||"" : "",
                      header ? order.shipping_address&&order.shipping_address.country||"" : "",
                      order_item.tracking_number.blank? ? order_item.tracking_number : "'" +  order_item.tracking_number , 
                      order_item.quantity.to_s,
                      order_item.product&&order_item.product.price&&order_item.product.price.to_f,
                      order_item.artwork_id,
                      order_item.artwork_name,
                      order_item.artist_id,
                      order_item.artist_name,
                      order_item.unit_price.to_f*order_item.quantity.to_f,
                      order_item.product&&order_item.product.title]
                      
              header = false
            end
            
          end
        end
    rescue
      ExportCsvMailer.send_error(email_address).deliver and return

    end
    zipname = "orders_#{start_t.strftime("%b-%d-%Y")}-#{end_t.strftime("%b-%d-%Y")}.zip"
    zipfile_name = folder+zipname
    Zip::ZipFile.open(zipfile_name, Zip::ZipFile::CREATE) do |zipfile|
      zipfile.add(filename, folder + filename)
    end 
    begin   
      ExportCsvMailer.send_csv(email_address, start_t, end_t, folder, zipname).deliver
    rescue
      ExportCsvMailer.send_error(email_address).deliver
    end
    
    if File.exists?(zipfile_name)
      File.delete(zipfile_name)
    end
    
    if File.exists?(folder+filename)
      File.delete(folder+filename)
    end
    
  end
end
