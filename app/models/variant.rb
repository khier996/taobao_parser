class Variant < ActiveRecord::Base
  require 'watir'
  require 'nokogiri'
  require 'open-uri'
  require 'headless'

  belongs_to :product

  scope :parsed, -> { where(parsed: true) }
  scope :unparsed, -> { where(parsed: false) }

  def update_info(sku_info, shopify_product)
    if self.price != sku_info['promo_price'] || self.compare_at_price != sku_info['original_price']
      @shopify_product = shopify_product
      self.price = sku_info['promo_price']
      self.compare_at_price = sku_info['original_price']
      self.save

      shopify_variant = @shopify_product.variants.find { |v| v.sku == self.sku }
      shopify_variant.price = self.price
      shopify_variant.compare_at_price = self.compare_at_price
      shopify_variant.inventory_quantity = sku_info['quantity']
    end
  end

  def patch_unparsed_sku(sku_info, shopify_product)
    begin
      return if sku_info['quantity'] == 0
      @headless ||= Headless.new(display: rand(99))
      @headless.start
      @browser ||= Watir::Browser.new :chrome, :switches => %w[--no-sandbox]

      # @browser = Watir::Browser.new :chrome # for test on local machine

      @translator = Translator.new
      @shopify_product = shopify_product
      @sku_info = sku_info
      parse_sku
    ensure
      @browser.close if @browser
      @headless.destroy if @headless
    end
  end

  def parse_sku
    product_id = self.product.taobao_product_id
    url = "https://detail.tmall.com/item.htm?id=#{product_id}&skuId=#{self.sku}"
    @browser.goto(url)
    @browser.wait(5)

    return if @browser.url != url

    find_option_indexes
    read_sku_info
  end

  def find_option_indexes
    @option_indexes = {}
    @shopify_product.options.each_with_index do |option, index|
      @option_indexes[option.name] = index
    end
  end

  def read_sku_info
    new_variant = create_variant
    doc = Nokogiri::HTML(@browser.html)
    props = doc.css('.tb-sku .tb-selected')
    props.each do |prop|
      prop_name = prop.parent.attributes['data-property'].value
      prop_value = prop.css('span').text
      prop_name = @translator.translate(prop_name)
      prop_value = @translator.translate(prop_value) unless prop_value == prop_value.to_i.to_s # prop_value is a number and doesn't need translation

      option = "option#{@option_indexes[prop_name] + 1}"
      new_variant[option] = prop_value
      find_prop_image(prop)
    end

    new_variant = ShopifyAPI::Variant.create(new_variant)
    if new_variant.errors.messages.empty?
      self.update(shopify_variant_id: new_variant.id, parsed: true)
      create_variant_image(new_variant)
    end
  end

  def find_prop_image(prop)
    style = prop.css('a').first.attributes['style']
    return if style.nil?
    variant_img = style.value.scan(/\(.*\)/).first.tr('()', '') unless style.nil?
    variant_img = 'https:' + variant_img.sub('jpg_40x40q90', 'jpg_600x600q90')
    @variant_img = {'src': variant_img}
  end

  def create_variant_image(new_variant)
    return unless @variant_img
    @variant_img['product_id'] = @shopify_product.id
    @variant_img['variant_ids'] = [new_variant.id]
    variant_image = ShopifyAPI::Image.create(@variant_img)
  end

  def create_variant
    data = {
        "compare_at_price" => @sku_info['original_price'],
        "fulfillment_service" => "manual",
        "inventory_management" => "shopify",
        "inventory_policy" => "continue",
        "inventory_quantity" => @sku_info['quantity'],
        "price" => @sku_info['promo_price'],
        "product_id" => @shopify_product.id,
        "requires_shipping" => true,
        "sku" => self.sku,
        "title" => "pink#{rand(100)}",
      }
  end

end



