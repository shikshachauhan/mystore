Spree::CheckoutController.class_eval do
  after_action :remove_missing_variants, only: :update
  def before_payment
    @order.bill_address ||= Spree::Address.build_default
    @order.ship_address ||= Spree::Address.build_default


    if try_spree_current_user && try_spree_current_user.respond_to?(:payment_sources)
      @payment_sources = try_spree_current_user.payment_sources
    end
  end

  def remove_missing_variants
    packages = @order.shipments.map(&:to_package)
    @differentiator = Spree::Stock::Differentiator.new(@order, packages)
    @differentiator.missing.each do |variant, quantity|
      @order.contents.remove(variant, quantity)
    end
  end
end
