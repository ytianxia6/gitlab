class ProjectMember < Member
  SOURCE_TYPE = 'Project'.freeze

  include Gitlab::ShellAdapter

  belongs_to :project, foreign_key: 'source_id'

  # Make sure project member points only to project as it source
  default_value_for :source_type, SOURCE_TYPE
  validates :source_type, format: { with: /\AProject\z/ }
  validates :access_level, inclusion: { in: Gitlab::Access.values }
  default_scope { where(source_type: SOURCE_TYPE) }

  scope :in_project, ->(project) { where(source_id: project.id) }

  before_destroy :delete_member_todos

  class << self
    # Add users to projects with passed access option
    #
    # access can be an integer representing a access code
    # or symbol like :master representing role
    #
    # Ex.
    #   add_users_to_projects(
    #     project_ids,
    #     user_ids,
    #     ProjectMember::MASTER
    #   )
    #
    #   add_users_to_projects(
    #     project_ids,
    #     user_ids,
    #     :master
    #   )
    #
    def add_users_to_projects(project_ids, users, access_level, current_user: nil, expires_at: nil)
      self.transaction do
        project_ids.each do |project_id|
          project = Project.find(project_id)

          add_users(
            project,
            users,
            access_level,
            current_user: current_user,
            expires_at: expires_at
          )
        end
      end
    end

    def truncate_teams(project_ids)
      ProjectMember.transaction do
        members = ProjectMember.where(source_id: project_ids)

        members.each do |member|
          member.destroy
        end
      end

      true
    rescue
      false
    end

    def truncate_team(project)
      truncate_teams [project.id]
    end

    def access_level_roles
      Gitlab::Access.options
    end

    private

    def can_update_member?(current_user, member)
      super || (member.owner? && member.new_record?)
    end
  end

  def real_source_type_zh
    '项目'
  end

  def project
    source
  end

  def owner?
    project.owner == user
  end

  private

  def delete_member_todos
    user.todos.where(project_id: source_id).destroy_all if user
  end

  def send_invite
    notification_service.invite_project_member(self, @raw_invite_token)

    super
  end

  def post_create_hook
    unless owner?
      event_service.join_project(self.project, self.user)
      notification_service.new_project_member(self)
    end

    super
  end

  def post_update_hook
    if access_level_changed?
      notification_service.update_project_member(self)
    end

    super
  end

  def post_destroy_hook
    if expired?
      event_service.expired_leave_project(self.project, self.user)
    else
      event_service.leave_project(self.project, self.user)
    end

    super
  end

  def after_accept_invite
    notification_service.accept_project_invite(self)

    super
  end

  def after_decline_invite
    notification_service.decline_project_invite(self)

    super
  end

  def event_service
    EventCreateService.new
  end
end
