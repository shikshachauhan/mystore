Spree::Order.class_eval do
  checkout_flow do
    go_to_state :payment
    go_to_state :complete
  end


  def assign_default_addresses!
    if user
      clone_billing
      # Skip setting ship address if order doesn't have a delivery checkout step
      # to avoid triggering validations on shipping address
      clone_shipping
    end
  end

  def self.define_state_machine!

    self.checkout_steps = {}
    self.next_event_transitions = []
    self.previous_states = [:cart]
    self.removed_transitions = []

    # Build the checkout flow using the checkout_flow defined either
    # within the Order class, or a decorator for that class.
    #
    # This method may be called multiple times depending on if the
    # checkout_flow is re-defined in a decorator or not.
    instance_eval(&checkout_flow)

    klass = self

    # To avoid a ton of warnings when the state machine is re-defined
    StateMachines::Machine.ignore_method_conflicts = true
    # To avoid multiple occurrences of the same transition being defined
    # On first definition, state_machines will not be defined
    state_machines.clear if respond_to?(:state_machines)
    state_machine :state, initial: :cart, use_transactions: false, action: :save_state do
      klass.next_event_transitions.each { |t| transition(t.merge(on: :next)) }

      # Persist the state on the order
      after_transition do |order, transition|
        order.state = order.state
        order.state_changes.create(
          previous_state: transition.from,
          next_state: transition.to,
          name: 'order',
          user_id: order.user_id
        )
        order.save
      end

      event :cancel do
        transition to: :canceled, if: :allow_cancel?
      end

      event :return do
        transition to: :returned,
                   from: [:complete, :awaiting_return, :canceled],
                   if: :all_inventory_units_returned?
      end

      event :resume do
        transition to: :resumed, from: :canceled, if: :canceled?
      end

      event :authorize_return do
        transition to: :awaiting_return
      end


      before_transition to: :complete do |order|
        order.create_proposed_shipments
        order.set_shipments_cost
        order.create_tax_charge!
        order.apply_free_shipping_promotions
        if order.payment_required? && order.payments.valid.empty?
          order.errors.add(:base, Spree.t(:no_payment_found))
          false
        elsif order.payment_required?
          order.process_payments!
        end
      end
      after_transition to: :complete, do: :persist_user_credit_card
      # before_transition to: :payment, do: :set_shipments_cost
      # before_transition to: :payment, do: :create_tax_charge!
      before_transition to: :payment, do: :assign_default_credit_card


      before_transition from: :cart, do: :ensure_line_items_present

      # if states[:address]
        # before_transition from: :address, do: :create_tax_charge!
      before_transition to: :payment, do: :assign_default_addresses!
      before_transition from: :payment, do: :persist_user_address!
      # end

      # if states[:delivery]
        # before_transition to: :delivery, do: :create_proposed_shipments
        # before_transition to: :delivery, do: :ensure_available_shipping_rates
        # before_transition to: :delivery, do: :set_shipments_cost
        # before_transition from: :delivery, do: :apply_free_shipping_promotions
      # end

      before_transition to: :resumed, do: :ensure_line_item_variants_are_not_deleted
      before_transition to: :resumed, do: :ensure_line_items_are_in_stock

      before_transition to: :complete, do: :ensure_line_item_variants_are_not_deleted
      before_transition to: :complete, do: :ensure_line_items_are_in_stock

      after_transition to: :complete, do: :finalize!
      after_transition to: :resumed, do: :after_resume
      after_transition to: :canceled, do: :after_cancel

      after_transition from: any - :cart, to: any - [:confirm, :complete] do |order|
        order.update_totals
        order.persist_totals
      end
    end

    alias_method :save_state, :save
  end
  define_state_machine!
end
