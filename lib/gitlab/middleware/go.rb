# A dumb middleware that returns a Go HTML document if the go-get=1 query string
# is used irrespective if the namespace/project exists
module Gitlab
  module Middleware
    class Go
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)

        if go_request?(request)
          render_go_doc(request)
        else
          @app.call(env)
        end
      end

      private

      def render_go_doc(request)
        body = go_body(request)
        response = Rack::Response.new(body, 200, { 'Content-Type' => 'text/html' })
        response.finish
      end

      def go_request?(request)
        request["go-get"].to_i == 1 && request.env["PATH_INFO"].present?
      end

      def go_body(request)
        project_url = URI.join(Gitlab.config.gitlab.url, project_path(request))
        import_prefix = strip_url(project_url.to_s)

        "<!DOCTYPE html><html><head><meta content='#{import_prefix} git #{project_url}.git' name='go-import'></head></html>\n"
      end

      def strip_url(url)
        url.gsub(/\Ahttps?:\/\//, '')
      end

      def project_path(request)
        path_info = request.env["PATH_INFO"]
        path_info.sub!(/^\//, '')

        # Go subpackages may be in the form of `namespace/project/path1/path2/../pathN`.
        # In a traditional project with a single namespace, this would denote repo
        # `namespace/project` with subpath `path1/path2/../pathN`, but with nested
        # groups, this could also be `namespace/project/path1` with subpath
        # `path2/../pathN`, for example.

        # We find all potential project paths out of the path segments
        path_segments = path_info.split('/')
        simple_project_path = path_segments.first(2).join('/')

        # If the path is at most 2 segments long, it is a simple `namespace/project` path and we're done
        return simple_project_path if path_segments.length <= 2

        project_paths = []
        begin
          project_paths << path_segments.join('/')
          path_segments.pop
        end while path_segments.length >= 2

        # We see if a project exists with any of these potential paths
        project = project_for_paths(project_paths, request)

        if project
          # If a project is found and the user has access, we return the full project path
          project.full_path
        else
          # If not, we return the first two components as if it were a simple `namespace/project` path,
          # so that we don't reveal the existence of a nested project the user doesn't have access to.
          # This means that for an unauthenticated request to `group/subgroup/project/subpackage`
          # for a private `group/subgroup/project` with subpackage path `subpackage`, GitLab will respond
          # as if the user is looking for project `group/subgroup`, with subpackage path `project/subpackage`.
          # Since `go get` doesn't authenticate by default, this means that
          # `go get gitlab.com/group/subgroup/project/subpackage` will not work for private projects.
          # `go get gitlab.com/group/subgroup/project.git/subpackage` will work, since Go is smart enough
          # to figure that out. `import 'gitlab.com/...'` behaves the same as `go get`.
          simple_project_path
        end
      end

      def project_for_paths(paths, request)
        project = Project.where_full_path_in(paths).first
        return unless Ability.allowed?(current_user(request), :read_project, project)

        project
      end

      def current_user(request)
        request.env['warden']&.authenticate
      end
    end
  end
end
