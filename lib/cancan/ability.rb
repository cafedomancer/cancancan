module CanCan
  # This module is designed to be included into an Ability class. This will
  # provide the "can" methods for defining and checking abilities.
  #
  #   class Ability
  #     include CanCan::Ability
  #
  #     def initialize(user)
  #       if user.admin?
  #         can :manage, :all
  #       else
  #         can :read, :all
  #       end
  #     end
  #   end
  #
  module Ability
    # Check if the user has permission to perform a given action on an object.
    #
    #   can? :destroy, @project
    #
    # You can also pass the class instead of an instance (if you don't have one handy).
    #
    #   can? :create, Project
    #
    # Nested resources can be passed through a hash, this way conditions which are
    # dependent upon the association will work when using a class.
    #
    #   can? :create, @category => Project
    #
    # You can also pass multiple objects to check. You only need to pass a hash
    # following the pattern { :any => [many subjects] }. The behaviour is check if
    # there is a permission on any of the given objects.
    #
    #   can? :create, {:any => [Project, Rule]}
    #
    #
    # Any additional arguments will be passed into the "can" block definition. This
    # can be used to pass more information about the user's request for example.
    #
    #   can? :create, Project, request.remote_ip
    #
    #   can :create, Project do |project, remote_ip|
    #     # ...
    #   end
    #
    # Not only can you use the can? method in the controller and view (see ControllerAdditions),
    # but you can also call it directly on an ability instance.
    #
    #   ability.can? :destroy, @project
    #
    # This makes testing a user's abilities very easy.
    #
    #   def test "user can only destroy projects which he owns"
    #     user = User.new
    #     ability = Ability.new(user)
    #     assert ability.can?(:destroy, Project.new(:user => user))
    #     assert ability.cannot?(:destroy, Project.new)
    #   end
    #
    # Also see the RSpec Matchers to aid in testing.
    def can?(action, subject, *extra_args)
      match = extract_subjects(subject).lazy.map do |a_subject|
        relevant_rules_for_match(action, a_subject).detect do |rule|
          rule.matches_conditions?(action, a_subject, extra_args)
        end
      end.reject(&:nil?).first
      match ? match.base_behavior : false
    end

    # Convenience method which works the same as "can?" but returns the opposite value.
    #
    #   cannot? :destroy, @project
    #
    def cannot?(*args)
      !can?(*args)
    end

    # Defines which abilities are allowed using two arguments. The first one is the action
    # you're setting the permission for, the second one is the class of object you're setting it on.
    #
    #   can :update, Article
    #
    # You can pass an array for either of these parameters to match any one.
    # Here the user has the ability to update or destroy both articles and comments.
    #
    #   can [:update, :destroy], [Article, Comment]
    #
    # You can pass :all to match any object and :manage to match any action. Here are some examples.
    #
    #   can :manage, :all
    #   can :update, :all
    #   can :manage, Project
    #
    # You can pass a hash of conditions as the third argument. Here the user can only see active projects which he owns.
    #
    #   can :read, Project, :active => true, :user_id => user.id
    #
    # See ActiveRecordAdditions#accessible_by for how to use this in database queries. These conditions
    # are also used for initial attributes when building a record in ControllerAdditions#load_resource.
    #
    # If the conditions hash does not give you enough control over defining abilities, you can use a block
    # along with any Ruby code you want.
    #
    #   can :update, Project do |project|
    #     project.groups.include?(user.group)
    #   end
    #
    # If the block returns true then the user has that :update ability for that project, otherwise he
    # will be denied access. The downside to using a block is that it cannot be used to generate
    # conditions for database queries.
    #
    # You can pass custom objects into this "can" method, this is usually done with a symbol
    # and is useful if a class isn't available to define permissions on.
    #
    #   can :read, :stats
    #   can? :read, :stats # => true
    #
    # IMPORTANT: Neither a hash of conditions nor a block will be used when checking permission on a class.
    #
    #   can :update, Project, :priority => 3
    #   can? :update, Project # => true
    #
    # If you pass no arguments to +can+, the action, class, and object will be passed to the block and the
    # block will always be executed. This allows you to override the full behavior if the permissions are
    # defined in an external source such as the database.
    #
    #   can do |action, object_class, object|
    #     # check the database and return true/false
    #   end
    #
    def can(action = nil, subject = nil, conditions = nil, &block)
      add_rule(Rule.new(true, action, subject, conditions, block))
    end

    # Defines an ability which cannot be done. Accepts the same arguments as "can".
    #
    #   can :read, :all
    #   cannot :read, Comment
    #
    # A block can be passed just like "can", however if the logic is complex it is recommended
    # to use the "can" method.
    #
    #   cannot :read, Product do |product|
    #     product.invisible?
    #   end
    #
    def cannot(action = nil, subject = nil, conditions = nil, &block)
      add_rule(Rule.new(false, action, subject, conditions, block))
    end

    # Alias one or more actions into another one.
    #
    #   alias_action :update, :destroy, :to => :modify
    #   can :modify, Comment
    #
    # Then :modify permission will apply to both :update and :destroy requests.
    #
    #   can? :update, Comment # => true
    #   can? :destroy, Comment # => true
    #
    # This only works in one direction. Passing the aliased action into the "can?" call
    # will not work because aliases are meant to generate more generic actions.
    #
    #   alias_action :update, :destroy, :to => :modify
    #   can :update, Comment
    #   can? :modify, Comment # => false
    #
    # Unless that exact alias is used.
    #
    #   can :modify, Comment
    #   can? :modify, Comment # => true
    #
    # The following aliases are added by default for conveniently mapping common controller actions.
    #
    #   alias_action :index, :show, :to => :read
    #   alias_action :new, :to => :create
    #   alias_action :edit, :to => :update
    #
    # This way one can use params[:action] in the controller to determine the permission.
    def alias_action(*args)
      target = args.pop[:to]
      validate_target(target)
      aliased_actions[target] ||= []
      aliased_actions[target] += args
    end

    # User shouldn't specify targets with names of real actions or it will cause Seg fault
    def validate_target(target)
      error_message = "You can't specify target (#{target}) as alias because it is real action name"
      raise Error, error_message if aliased_actions.values.flatten.include? target
    end

    # Returns a hash of aliased actions. The key is the target and the value is an array of actions aliasing the key.
    def aliased_actions
      @aliased_actions ||= default_alias_actions
    end

    # Removes previously aliased actions including the defaults.
    def clear_aliased_actions
      @aliased_actions = {}
    end

    def model_adapter(model_class, action)
      adapter_class = ModelAdapters::AbstractAdapter.adapter_class(model_class)
      adapter_class.new(model_class, relevant_rules_for_query(action, model_class))
    end

    # See ControllerAdditions#authorize! for documentation.
    def authorize!(action, subject, *args)
      message = nil
      if args.last.is_a?(Hash) && args.last.key?(:message)
        message = args.pop[:message]
      end
      if cannot?(action, subject, *args)
        message ||= unauthorized_message(action, subject)
        raise AccessDenied.new(message, action, subject)
      end
      subject
    end

    def unauthorized_message(action, subject)
      keys = unauthorized_message_keys(action, subject)
      variables = { action: action.to_s }
      variables[:subject] = (subject.class == Class ? subject : subject.class).to_s.underscore.humanize.downcase
      message = I18n.translate(nil, variables.merge(scope: :unauthorized, default: keys + ['']))
      message.blank? ? nil : message
    end

    def attributes_for(action, subject)
      attributes = {}
      relevant_rules(action, subject).map do |rule|
        attributes.merge!(rule.attributes_from_conditions) if rule.base_behavior
      end
      attributes
    end

    def has_block?(action, subject)
      relevant_rules(action, subject).any?(&:only_block?)
    end

    def has_raw_sql?(action, subject)
      relevant_rules(action, subject).any?(&:only_raw_sql?)
    end

    def merge(ability)
      ability.rules.each do |rule|
        add_rule(rule.dup)
      end
      self
    end

    # Return a hash of permissions for the user in the format of:
    #   {
    #     can: can_hash,
    #     cannot: cannot_hash
    #   }
    #
    # Where can_hash and cannot_hash are formatted thusly:
    #   {
    #     action: array_of_objects
    #   }
    def permissions
      permissions_list = { can: {}, cannot: {} }

      rules.each do |rule|
        subjects = rule.subjects
        expand_actions(rule.actions).each do |action|
          if rule.base_behavior
            permissions_list[:can][action] ||= []
            permissions_list[:can][action] += subjects.map(&:to_s)
          else
            permissions_list[:cannot][action] ||= []
            permissions_list[:cannot][action] += subjects.map(&:to_s)
          end
        end
      end

      permissions_list
    end

    protected

    # Must be protected as an ability can merge with other abilities.
    # This means that an ability must expose their rules with another ability.
    def rules
      @rules ||= []
    end

    private

    def unauthorized_message_keys(action, subject)
      subject = (subject.class == Class ? subject : subject.class).name.underscore unless subject.is_a? Symbol
      aliases = aliases_for_action(action)
      [subject, :all].product([*aliases, :manage]).map do |try_subject, try_action|
        :"#{try_action}.#{try_subject}"
      end
    end

    # Accepts an array of actions and returns an array of actions which match.
    # This should be called before "matches?" and other checking methods since they
    # rely on the actions to be expanded.
    def expand_actions(actions)
      expanded_actions[actions] ||= begin
        expanded = []
        actions.each do |action|
          expanded << action
          if (aliases = aliased_actions[action])
            expanded += expand_actions(aliases)
          end
        end
        expanded
      end
    end

    def expanded_actions
      @expanded_actions ||= {}
    end

    # It translates to an array the subject or the hash with multiple subjects given to can?.
    def extract_subjects(subject)
      if subject.is_a?(Hash) && subject.key?(:any)
        subject[:any]
      else
        [subject]
      end
    end

    # Given an action, it will try to find all of the actions which are aliased to it.
    # This does the opposite kind of lookup as expand_actions.
    def aliases_for_action(action)
      results = [action]
      aliased_actions.each do |aliased_action, actions|
        results += aliases_for_action(aliased_action) if actions.include? action
      end
      results
    end

    def add_rule(rule)
      rules << rule
      add_rule_to_index(rule, rules.size - 1)
    end

    def add_rule_to_index(rule, position)
      @rules_index ||= Hash.new { |h, k| h[k] = [] }

      subjects = rule.subjects.compact
      subjects << :all if subjects.empty?

      subjects.each do |subject|
        @rules_index[subject] << position
      end
    end

    def alternative_subjects(subject)
      subject = subject.class unless subject.is_a?(Module)
      [:all, *subject.ancestors,  subject.class.to_s]
    end

    # Returns an array of Rule instances which match the action and subject
    # This does not take into consideration any hash conditions or block statements
    def relevant_rules(action, subject)
      return [] unless @rules
      relevant = possible_relevant_rules(subject).select do |rule|
        rule.expanded_actions = expand_actions(rule.actions)
        rule.relevant? action, subject
      end
      relevant.reverse!.uniq!
      optimize_order! relevant
      relevant
    end

    # Optimizes the order of the rules, so that rules with the :all subject are evaluated first.
    def optimize_order!(rules)
      first_can_in_group = -1
      rules.each_with_index do |rule, i|
        (first_can_in_group = -1) && next unless rule.base_behavior
        (first_can_in_group = i) && next if first_can_in_group == -1
        next unless rule.subjects == [:all]
        rules[i] = rules[first_can_in_group]
        rules[first_can_in_group] = rule
        first_can_in_group += 1
      end
    end

    def possible_relevant_rules(subject)
      if subject.is_a?(Hash)
        rules
      else
        positions = @rules_index.values_at(subject, *alternative_subjects(subject))
        positions.flatten!.sort!
        positions.map { |i| @rules[i] }
      end
    end

    def relevant_rules_for_match(action, subject)
      relevant_rules(action, subject).each do |rule|
        next unless rule.only_raw_sql?
        raise Error,
              "The can? and cannot? call cannot be used with a raw sql 'can' definition."\
              " The checking code cannot be determined for #{action.inspect} #{subject.inspect}"
      end
    end

    def relevant_rules_for_query(action, subject)
      relevant_rules(action, subject).each do |rule|
        if rule.only_block?
          raise Error, "The accessible_by call cannot be used with a block 'can' definition."\
                       " The SQL cannot be determined for #{action.inspect} #{subject.inspect}"
        end
      end
    end

    def default_alias_actions
      {
        read: %i[index show],
        create: [:new],
        update: [:edit]
      }
    end
  end
end
