module Trello

  # A board on Trello
  #
  # @!attribute [r] id
  #   @return [String]
  # @!attribute [r] name
  #   @return [String]
  # @!attribute [rw] description
  #   @return [String]
  # @!attribute [rw] closed
  #   @return [Boolean]
  # @!attribute [r] url
  #   @return [String]
  # @!attribute [rw] organization_id
  #   @return [String] A 24-character hex string
  # @!attribute [r] prefs
  #   @return [Hash] A 24-character hex string
  class Board < BasicData
    register_attributes :id, :name, :description, :closed, :starred, :url, :organization_id, :prefs, :last_activity_date,
      readonly: [ :id, :url, :last_activity_date ]
    validates_presence_of :id, :name
    validates_length_of   :name,        in: 1..16384
    validates_length_of   :description, maximum: 16384

    include HasActions

    class << self
      # Finds a board.
      #
      # @param [String] id Either the board's short ID (an alphanumeric string,
      #     found e.g. in the board's URL) or its long ID (a 24-character hex
      #     string.)
      # @param [Hash] params
      #
      # @raise  [Trello::Board] if a board with the given ID could not be found.
      #
      # @return [Trello::Board]
      def find(id, params = {})
        client.find(:board, id, params)
      end

      def create(fields)
        data = {
          'name'   => fields[:name],
          'desc'   => fields[:description],
          'closed' => fields[:closed] || false,
          'starred' => fields[:starred] || false }
        data.merge!('idOrganization' => fields[:organization_id]) if fields[:organization_id]
        data.merge!('prefs' => fields[:prefs]) if fields[:prefs]
        client.create(:board, data)
      end

      # @return [Array<Trello::Board>] all boards for the current user
      def all
        from_response client.get("/members/#{Member.find(:me).username}/boards")
      end
    end

    def save
      return update! if id

      fields = { name: name }
      fields.merge!(desc: description) if description
      fields.merge!(idOrganization: organization_id) if organization_id
      fields.merge!(flat_prefs)

      from_response(client.post("/boards", fields))
    end

    def update!
      fail "Cannot save new instance." unless self.id

      @previously_changed = changes
      @changed_attributes.clear

      fields = {
        name: attributes[:name],
        description: attributes[:description],
        closed: attributes[:closed],
        starred: attributes[:starred],
        idOrganization: attributes[:organization_id]
      }
      fields.merge!(flat_prefs)

      from_response client.put("/boards/#{self.id}/", fields)
    end

    def update_fields(fields)
      attributes[:id]              = fields['id'] || fields[:id]                          if fields['id']   || fields[:id]
      attributes[:name]            = fields['name'] || fields[:name]                      if fields['name'] || fields[:name]
      attributes[:description]     = fields['desc'] || fields[:desc]                      if fields['desc'] || fields[:desc]
      attributes[:closed]          = fields['closed']                                     if fields.has_key?('closed')
      attributes[:closed]          = fields[:closed]                                      if fields.has_key?(:closed)
      attributes[:starred]         = fields['starred']                                    if fields.has_key?('starred')
      attributes[:starred]         = fields[:starred]                                     if fields.has_key?(:starred)
      attributes[:url]             = fields['url']                                        if fields['url']
      attributes[:organization_id] = fields['idOrganization'] || fields[:organization_id] if fields['idOrganization'] || fields[:organization_id]
      attributes[:prefs]           = fields['prefs'] || fields[:prefs] || {}
      attributes[:last_activity_date] = Time.iso8601(fields['dateLastActivity']) rescue nil
      self
    end

    # @return [Boolean]
    def closed?
      attributes[:closed]
    end

    # @return [Boolean]
    def starred?
      attributes[:starred]
    end

    # @return [Boolean]
    def has_lists?
      lists.size > 0
    end

    # Find a card on this Board with the given ID.
    # @return [Trello::Card]
    def find_card(card_id)
      Card.from_response client.get("/boards/#{self.id}/cards/#{card_id}")
    end

    # Add a member to this Board.
    #    type => [ :admin, :normal, :observer ]
    def add_member(member, type = :normal)
      client.put("/boards/#{self.id}/members/#{member.id}", { type: type })
    end

    # Remove a member of this Board.
    def remove_member(member)
      client.delete("/boards/#{self.id}/members/#{member.id}")
    end

    # Return all the cards on this board.
    #
    # This method, when called, can take a hash table with a filter key containing any
    # of the following values:
    #    :filter => [ :none, :open, :closed, :all ] # default :open
    many :cards, filter: :open

    # Returns all the lists on this board.
    #
    # This method, when called, can take a hash table with a filter key containing any
    # of the following values:
    #    :filter => [ :none, :open, :closed, :all ] # default :open
    many :lists, filter: :open

    # Returns an array of members who are associated with this board.
    #
    # This method, when called, can take a hash table with a filter key containing any
    # of the following values:
    #    :filter => [ :none, :normal, :owners, :admins, :all ] # default :all
    many :members, filter: :all

    # Returns a list of checklists associated with the board.
    #
    # The options hash may have a filter key which can have its value set as any
    # of the following values:
    #    :filter => [ :none, :all ] # default :all
    many :checklists, filter: :all

    # Returns a reference to the organization this board belongs to.
    one :organization, path: :organizations, using: :organization_id

    # Returns a list of plugins associated with the board
    many :plugin_data, path: "pluginData"

    # Returns custom fields activated on this board
    many :custom_fields, path: "customFields"

    def labels(params = {})
      # Set the limit to as high as possible given there is no pagination in this API.
      params[:limit] = 1000 unless params[:limit]
      labels = Label.from_response client.get("/boards/#{id}/labels", params)
      MultiAssociation.new(self, labels).proxy
    end

    def label_names
      label_names = LabelName.from_response client.get("/boards/#{id}/labelnames")
      MultiAssociation.new(self, label_names).proxy
    end

    # :nodoc:
    def request_prefix
      "/boards/#{id}"
    end

    private

    # On creation
    # https://trello.com/docs/api/board/#post-1-boards
    # - permissionLevel
    # - voting
    # - comments
    # - invitations
    # - selfJoin
    # - cardCovers
    # - background
    # - cardAging
    #
    # On update
    # https://trello.com/docs/api/board/#put-1-boards-board-id
    # Same as above plus:
    # - calendarFeedEnabled
    def flat_prefs
      separator = id ? "/" : "_"
      attributes[:prefs].inject({}) do |hash, (pref, v)|
        hash.merge("prefs#{separator}#{pref}" => v)
      end
    end
  end
end
