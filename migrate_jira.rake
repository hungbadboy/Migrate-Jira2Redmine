require 'rexml/document'
require 'active_record'
require 'nokogiri'
require 'yaml'
require 'fileutils'
require File.expand_path('../../../config/environment', __FILE__) # Assumes that migrate_jira.rake is in lib/tasks/

# require 'byebug'

module JiraMigration
  include Nokogiri
# rake jira_migration:do_all_migrations RAILS_ENV="production"# Tests all parsers!
# rake jira_migration:generate_conf RAILS_ENV="production" # Generates the configuration for the map things from Jira to Redmine
# rake jira_migration:migrate_attachments RAILS_ENV="production" # Migrates Jira Issues Attachments to Redmine Attachments
# rake jira_migration:migrate_comments RAILS_ENV="production"# Migrates Jira Issues Comments to Redmine Issues Journals (Notes)
# rake jira_migration:migrate_issue_priorities RAILS_ENV="production" # Migrates Jira Issue Priorities to Redmine Priorities
# rake jira_migration:migrate_issue_status RAILS_ENV="production"# Migrates Jira Issue Status to Redmine Status
# rake jira_migration:migrate_issue_types RAILS_ENV="production"# Migrates Jira Issue Types to Redmine Trackes
# rake jira_migration:migrate_issues RAILS_ENV="production"# Migrates Jira Issues to Redmine Issues
# rake jira_migration:migrate_projects RAILS_ENV="production"# Migrates Jira Projects to Redmine Projects
# rake jira_migration:migrate_users RAILS_ENV="production"# Migrates Jira Users to Redmine Users
# rake jira_migration:pre_conf RAILS_ENV="production"# Gets the configuration from YAML
# rake jira_migration:test_all_migrations RAILS_ENV="production"# Tests all parsers!
# rake jira_migration:test_parse_comments RAILS_ENV="production"# Just pretty print Jira Comments on screen
# rake jira_migration:test_parse_issues RAILS_ENV="production"# Just pretty print Jira Issues on screen
# rake jira_migration:test_parse_projects RAILS_ENV="production"# Just pretty print Jira Projects on screen
# rake jira_migration:test_parse_users RAILS_ENV="production"l# Just pretty print Jira Users on screen

  ############## Configuration mapping file. Maps Jira Entities to Redmine Entities. Generated on the first run.
  CONF_FILE = 'map_jira_to_redmine.yml'
  ############## Jira backup main xml file with all data
  ENTITIES_FILE = '/home/redmine/JIRA-backup-20150303/entities.xml'
  ############## Location of jira attachements
  #JIRA_ATTACHMENTS_DIR = 'attachments'
	JIRA_ATTACHMENTS_DIR = '/home/redmine/JIRA-backup-20150303/data/attachments'
  ############## Jira URL
   $JIRA_WEB_URL = 'https://nissho-osd.atlassian.net'
  #$JIRA_WEB_URL = 'https://glorium.jira.com'd
  #$JIRA_WEB_URL = 'https://leasepipeline.atlassian.net'

  class BaseJira

    MAP = {}

    attr_reader :tag
    attr_accessor :new_record, :is_new

    def map
      self.class::MAP
    end

    def initialize(node)
      @tag = node
    end

    def method_missing(key, *args)
      if key.to_s.start_with?('jira_')
        attr = key.to_s.sub('jira_', '')
        return @tag[attr]
      end
      puts "Method missing: #{key}"
      raise NoMethodError key
    end

    def run_all_redmine_fields
      ret = {}
      self.methods.each do |method_name|
        m = method_name.to_s
        if m.start_with?('red_')
          mm = m.to_s.sub('red_', '')
          ret[mm] = self.send(m)
        end
      end
      return ret
    end

    def migrate
      all_fields = self.run_all_redmine_fields()
      pp('Saving:', all_fields)
      record = self.retrieve
      if record
        record.update_attributes(all_fields)
      else
        record = self.class::DEST_MODEL.new all_fields
        self.is_new = true
      end
      if self.respond_to?('before_save')
        self.before_save(record)
      end

      record.save!
      record.reload
      self.map[self.jira_id] = record
      self.new_record = record
      if self.respond_to?('post_migrate')
        self.post_migrate(record, self.is_new)
      end
      record.reload
      return record
    end
    def retrieve
      self.class::DEST_MODEL.find_by_name(self.jira_id)
    end
  end

  class JiraUser < BaseJira

    DEST_MODEL = User
    MAP = {}

    attr_accessor  :jira_emailAddress, :jira_name

    def initialize(node)
      super
    end
    
    def retrieve
      # Check mail address first, as it is more likely to match across systems
      user = self.class::DEST_MODEL.find_by_mail(self.jira_emailAddress.squish)
      if !user
        user = self.class::DEST_MODEL.find_by_login(self.jira_name.squish)
      end

      return user
    end

    def migrate
      super
      $MIGRATED_USERS_BY_NAME[self.jira_name] = self.new_record
    end

    # First Name, Last Name, E-mail, Password
    # here is the tranformation of Jira attributes in Redmine attribues
    def red_firstname
      firstName = self.jira_firstName
      if firstName.blank?
        firstName = "-"  
      end
      return firstName 
    end
    def red_lastname
      self.jira_lastName
    end
    def red_mail
      self.jira_emailAddress.squish
    end
    def red_login
      self.jira_name
    end
    def red_status
      status = "1"
      if self.jira_active.to_s == "0"
        status = "3"
      end
      return status
    end
    def before_save(new_record)
      new_record.login = red_login
      if new_record.new_record?
        new_record.salt_password('Pa$$w0rd')
      end
    end
    def post_migrate(new_record, is_new)
      if is_new
        new_record.update_attribute(:must_change_passwd, true)
        new_record.reload
      end
    end
  end

  class JiraGroup < BaseJira
    DEST_MODEL = Group
    MAP = {}

    def initialize(node)
      super
    end

    def retrieve
      group = self.class::DEST_MODEL.find_by_lastname(self.jira_lowerGroupName)
    end

    def red_name
      self.jira_lowerGroupName
    end
  end

  class JiraProject < BaseJira
    DEST_MODEL = Project
    MAP = {}

    def retrieve

      self.class::DEST_MODEL.find_by_identifier(self.red_identifier)
    end
    def post_migrate(new_record, is_new)
      if !new_record.module_enabled?('issue_tracking')
        new_record.enabled_modules << EnabledModule.new(:name => 'issue_tracking')
      end
      $MIGRATED_ISSUE_TYPES.values.uniq.each do |issue_type|
        if !new_record.trackers.include?(issue_type)
          new_record.trackers << issue_type
        end
      end
      new_record.update_column(:is_public, false)
      new_record.reload
    end

    # here is the tranformation of Jira attributes in Redmine attribues
    def red_name
      self.jira_name
    end
    def red_description
      self.jira_name
    end
    def red_identifier
      ret = self.jira_key.downcase
      return ret
    end
  end

  class JiraVersion < BaseJira

    DEST_MODEL = Version
    MAP = {}

    def jira_marker
      return "FROM JIRA: \"#{$MAP_PROJECT_ID_TO_PROJECT_KEY[self.jira_project]}\":#{$JIRA_WEB_URL}/browse/#{$MAP_PROJECT_ID_TO_PROJECT_KEY[self.jira_project]}\n"
    end

    def retrieve
      self.class::DEST_MODEL.find_by_name(self.jira_name)
    end

    def red_project
      # needs to return the Rails Project object
      JiraProject::MAP[self.jira_project]
    end

    def red_name
      self.jira_name
    end

    def red_description
      self.jira_description
    end

    def red_due_date
      if self.jira_releasedate
        Time.parse(self.jira_releasedate)
      end
    end

  end

  class JiraIssue < BaseJira

    DEST_MODEL = Issue
    MAP = {}

    attr_reader  :jira_description, :jira_reporter


    def initialize(node_tag)
      super
      if @tag.at('description')
        @jira_description = @tag.at('description').text
      else
        @jira_description = @tag['description']
      end
      #@jira_description = node_tag['description'].to_s
      @jira_reporter = node_tag['reporter'].to_s
    end
    def jira_marker
      return "FROM JIRA: \"#{self.jira_key}\":#{$JIRA_WEB_URL}/browse/#{self.jira_key}"
    end
    def retrieve
      Issue.where("description Like '#{self.jira_marker}%'").first()
    end

    def red_project
      # needs to return the Rails Project object
      JiraProject::MAP[self.jira_project]
    end

=begin
    def red_fixed_version
      path = "/*/NodeAssociation[@sourceNodeId=\"#{self.jira_id}\" and @sourceNodeEntity=\"Issue\" and @sinkNodeEntity=\"Version\" and @associationType=\"IssueFixVersion\"]"
      assocs = JiraMigration.get_list_from_tag(path)
      versions = []
      assocs.each do |assoc|
        version = JiraVersion::MAP[assoc["sinkNodeId"]]
        versions.push(version)
      end
      versions.last
    end
=end

    def red_subject
      self.jira_summary
    end
    def red_description
      "#{self.jira_marker}\n%s" % @jira_description
      #dsc = self.jira_marker + "\n"
      #if @jira_description
      #  dsc += @jira_description
      #else
      #  dsc += self.red_subject
      #end
      #return dsc
    end
    def red_priority
      name = $MIGRATED_ISSUE_PRIORITIES_BY_ID[self.jira_priority]
      return $MIGRATED_ISSUE_PRIORITIES[name]
    end
    def red_created_on
      Time.parse(self.jira_created)
    end
    def red_updated_on
      Time.parse(self.jira_updated)
    end
    def red_estimated_hours
      self.jira_timeestimate.to_s.empty? ? 0 : self.jira_timeestimate.to_f / 3600
    end
    # def red_start_date
    #   Time.parse(self.jira_created)
    # end
    def red_due_date
      Time.parse(self.jira_resolutiondate) if self.jira_resolutiondate
    end
    def red_status
      name = $MIGRATED_ISSUE_STATUS_BY_ID[self.jira_status]
      return $MIGRATED_ISSUE_STATUS[name]
    end
    def red_tracker
      type_name = $MIGRATED_ISSUE_TYPES_BY_ID[self.jira_type]
      type_name = type_name.gsub(':','')
      return $MIGRATED_ISSUE_TYPES[type_name]
    end
    def red_author
      JiraMigration.find_user_by_jira_name(self.jira_reporter)
    end
    def red_assigned_to
      if self.jira_assignee
        JiraMigration.find_user_by_jira_name(self.jira_assignee)
      else
        nil
      end
    end
    def post_migrate(new_record, is_new)
      new_record.update_column :updated_on, Time.parse(self.jira_updated)
      new_record.update_column :created_on, Time.parse(self.jira_created)
      new_record.reload
    end
  end

  class JiraComment < BaseJira

    DEST_MODEL = Journal
    MAP = {}

    def initialize(node)
      super
      # get a body from a comment
      # comment can have the comment body as a attribute or as a child tag
      if @tag["body"]
        @jira_body = @tag["body"] 
      else
        @jira_body =  @tag.at("body").text
      end      
    end

    def jira_marker
      return "FROM JIRA: #{self.jira_id}"
    end
    def retrieve
      Journal.where(notes: "LIKE '#{self.jira_marker}%'").first()
    end

    # here is the tranformation of Jira attributes in Redmine attribues
    def red_notes
      #self.jira_marker + "\n" + @jira_body
      "#{self.jira_marker}\n%s" % @jira_body
    end
    def red_created_on
      DateTime.parse(self.jira_created)
    end
    def red_user
      # retrieving the Rails object
      JiraMigration.find_user_by_jira_name(self.jira_author)
    end
    def red_journalized
      # retrieving the Rails object
      JiraIssue::MAP[self.jira_issue]
    end
    def post_migrate(new_record, is_new)
      new_record.update_column :created_on, Time.parse(self.jira_created)
      new_record.reload
    end
  end

  class JiraAttachment < BaseJira

    DEST_MODEL = Attachment
    MAP = {}

    def retrieve
      nil
    end

    def before_save(new_record)
      new_record.container = self.red_container
      #pp(new_record)

      # JIRA stores attachments as follows:
      # <PROJECTKEY>/<ISSUE-KEY>/<ATTACHMENT_ID>_filename.ext
      #
      # We have to recreate this path in order to copy the file
      issue_key = $MAP_ISSUE_TO_PROJECT_KEY[self.jira_issue][:issue_key]
      project_key = $MAP_ISSUE_TO_PROJECT_KEY[self.jira_issue][:project_key]
      jira_attachment_file = File.join(JIRA_ATTACHMENTS_DIR,
                                       project_key,
                                       issue_key,
                                       "#{self.jira_id}")
      #puts "Jira Attachment File: #{jira_attachment_file}"
      if File.exists? jira_attachment_file
        new_record.file = File.open(jira_attachment_file)
        #puts "Setting attachment #{jira_attachment_file} for record"
        # redmine_attachment_file = File.join(Attachment.storage_path, new_record.disk_filename)

        # puts "Copying attachment [#{jira_attachment_file}] to [#{redmine_attachment_file}]"
        # FileUtils.cp jira_attachment_file, redmine_attachment_file
      else
        #puts "Attachment file [#{jira_attachment_file}] not found. Skipping copy."
      end
    end

    # here is the tranformation of Jira attributes in Redmine attribues
    #<FileAttachment id="10084" issue="10255" mimetype="image/jpeg" filename="Landing_Template.jpg"
    #                created="2011-05-05 15:54:59.411" filesize="236515" author="emiliano"/>
    def red_filename
      self.jira_filename  # stole from Redmine: app/model/attachment (methods sanitize_filenanme)
    end
    # def red_disk_filename
    #   Attachment.disk_filename(self.jira_issue+self.jira_filename)
    # end
    def red_content_type
      self.jira_mimetype.to_s.chomp
    end
    # def red_filesize
    #   self.jira_filesize
    # end

    def red_created_on
      DateTime.parse(self.jira_created)
    end
    def red_author
      JiraMigration.find_user_by_jira_name(self.jira_author)
    end
    def red_container
      JiraIssue::MAP[self.jira_issue]
    end
    def post_migrate(new_record, is_new)
      new_record.update_column :created_on, Time.parse(self.jira_created)
      new_record.reload
    end
  end
  
  class JiraCustomField < BaseJira
    DEST_MODEL =  IssueCustomField
    MAP = {}
    
    def retrieve
      self.class::DEST_MODEL.find_by_name(self.jira_name)
    end
    
    def red_field_format
      DEFAULT_FORMAT_TYPE_CUSTOM_FIELD.fetch(self.jira_customfieldtypekey, FORMAT_TYPE_CUSTOM_FIELD_MARKER)
    end
    
    def red_type
      "IssueCustomField"
    end
    
    def red_name
      self.jira_name
    end
    
    def red_possible_values
      option = nil
      if self.red_field_format == 'list'
        options = {}
        option = ""
         $doc.xpath('/*/CustomFieldOption[@customfield="'+ self.jira_id + '"]').each do |v|
           option << v[:value] << "\n"
           options[v[:id]] = v[:value] 
         end
        #pp(option)
        pp(options)
        $MAP_FIELD_ID_SELECT_OPTIONS[self.jira_id] = options
       end      
      return option 
    end
    
    # def red_role_ids
      # role_ids = []
#       
    # end
    
    def red_tracker_ids
      tracker_ids = Set.new()
      $doc.xpath('/*/CustomFieldValue[@customfield="'+ self.jira_id + '"]').each do |v|
        issue = JiraIssue::MAP[v[:issue]]
        tracker_ids.add(issue.tracker_id)
      end
      return tracker_ids.to_a 
    end
    
    def red_project_ids
      #prorject by custom field id
      project_ids = Set.new()
        $doc.xpath('/*/CustomFieldValue[@customfield="'+ self.jira_id + '"]').each do |v|
        issue = JiraIssue::MAP[v[:issue]]
        project_ids.add(issue.project.id)
      end
       return project_ids.to_a
    end
    
    def post_migrate(new_record, is_new)
       if is_new
         new_record.reload
       end
     end
    
  end
  class JiraCustomFieldValue < BaseJira
    DEST_MODEL = CustomValue
    MAP = {}
    
    def retrieve
      #nil
      self.class::DEST_MODEL.where(["customized_id = ? and custom_field_id = ?", JiraIssue::MAP[self.jira_issue].id, $MAP_JIRA_CUSTOM_FIELD_ID_TO_REDMINE[self.jira_customfield]]).first()
    end
    
    def red_customized_id
      issue = JiraIssue::MAP[self.jira_issue]
      return issue.id 
    end
    
    def red_customized_type
      "Issue"
    end
    
    def red_custom_field_id
      $MAP_JIRA_CUSTOM_FIELD_ID_TO_REDMINE[self.jira_customfield]      
    end
    
    def red_value
      value = nil
      if !@tag["textvalue"].nil?
        value = self.jira_text_value
      end
      
      if !@tag.at("textvalue").nil?
        value = @tag.at("textvalue").text
      end
      
      if !@tag["numbervalue"].nil?
        value = self.jira_numbervalue
      end      
      if !@tag["stringvalue"].nil?  
        value = self.jira_stringvalue
      end
      
      if !@tag["datevalue"].nil?
        value = self.jira_datevalue
      end
      # get value option if field is select or list
      options = $MAP_FIELD_ID_SELECT_OPTIONS[self.jira_customfield]
      if !options.nil? and !value.nil?
        value = options[value]
      end
      return value
    end        
  end
  ISSUELINK_TYPE_MARKER = IssueRelation::TYPE_RELATES
  DEFAULT_ISSUELINK_TYPE_MAP = {
      # Default map from Jira (key) to Redmine (value)
      "Duplicate" => IssueRelation::TYPE_DUPLICATES,              # inward="is duplicated by" outward="duplicates"
      "Relates" => IssueRelation::TYPE_RELATES,  # inward="relates to" outward="relates to"
      "Blocked" => IssueRelation::TYPE_BLOCKS,  # inward="blocked by" outward="blocks"
      "Dependent" => IssueRelation::TYPE_FOLLOWS,            # inward="is depended on by" outward="depends on"
      "Epic-Story Link" => "Epic-Story",
      "jira_subtask_link" => "Subtask"
  }


  ISSUE_TYPE_MARKER = "(choose a Redmine Tracker)"
  DEFAULT_ISSUE_TYPE_MAP = {
      # Default map from Jira (key) to Redmine (value)
      # the comments on right side are Jira definitions - http://confluence.atlassian.com/display/JIRA/What+is+an+Issue#
        "Technical task" => "Technical task",
        "QA" => "QA",
        "CPCC CreateDocument-Task" => "CPCC CreateDocument-Task",
        "Comment" => "Comment",
        "Risk" => "Risk",
        "ACC: Create Environment Setup Guide Task" => "ACC: Create Environment Setup Guide Task",
        "ACC: Create Document Task" => "ACC: Create Document Task",
        "Bug" => " Bug",
        "New Feature" => "Feature",
        "Task" => "Task",
        "Improvement" => "Improvement",
        "Sub-task" => "Sub-task",
        "Epic" => "Epic",
        "Story" => "Story"
       }

  ISSUE_STATUS_MARKER = "(choose a Redmine Issue Status)"
  DEFAULT_ISSUE_STATUS_MAP = {
      # Default map from Jira (key) to Redmine (value)
      # the comments on right side are Jira definitions - http://confluence.atlassian.com/display/JIRA/What+is+an+Issue#
      "Open" => "New",                # This issue is in the initial 'Open' state, ready for the assignee to start work on it.
      "In Progress" => "In Progress", # This issue is being actively worked on at the moment by the assignee.
      "Resolved" => "Resolved",       # A Resolution has been identified or implemented, and this issue is awaiting verification by the reporter. From here, issues are either 'Reopened' or are 'Closed'.
      "Reopened" => "New",       # This issue was once 'Resolved' or 'Closed', but is now being re-examined. (For example, an issue with a Resolution of 'Cannot Reproduce' is Reopened when more information becomes available and the issue becomes reproducible). From here, issues are either marked In Progress, Resolved or Closed.
      "Closed" => "Closed",           # This issue is complete. ## Be careful to choose one which a "issue closed" attribute marked :-)
      "In Test" => "In Test",
      "Verified" => "Verified",
      "Building" => "Building",
      "Build Broken" => "Build Broken",
      "In Review" => "In Review",
      "Developing" => "Developing",
      "Review" => "Review",
      "Creating" => "Creating",
      "Customer Rejected" => "Customer Rejected",
      "Released" => "Released",
      "Assigned" => "Assigned",
      "Updating" => "Updating",
      "Development Finished" => "Development Finished",
      "Customer Review" => "Customer Review",
      "Reproducing" => "Reproducing",
      "Translating" => "Translating",
      "Irreproducible" => "Irreproducible",
      "Translation Review" => "Translation Review",
      "Team Lead Review" => "Team Lead Review",
      "To Do" => "To Do",
      "Done" => "Done",
      "Estimation Reviewing" => "Estimation Reviewing",
      "Estimation Approved" => "Estimation Approved",
      "Estimation Rejected" => "Estimation Rejected",
      "Customer Reviewing" => "Customer Reviewing",
      "Customer Approved" => "Customer Approved",
      "Translation Approved" => "Translation Approved",
      "Estimating" => "Estimating",
      "Estimation Completed" => "Estimation Completed",
      "Cancelled" => "Cancelled",
      "Answer Received" => "Answer Received",
      "T0 D0" => "T0 D0",
      "Question Sent" => "Question Sent"

  }

  ISSUE_PRIORITY_MARKER = "(choose a Redmine Enumeration Issue Priority)"
  DEFAULT_ISSUE_PRIORITY_MAP = {
      # Default map from Jira (key) to Redmine (value)
      # the comments on right side are Jira definitions - http://confluence.atlassian.com/display/JIRA/What+is+an+Issue#
      "Blocker" => "Blocker", # Highest priority. Indicates that this issue takes precedence over all others.
      "Critical" => "Urgent",   # Indicates that this issue is causing a problem and requires urgent attention.
      "Major" => "High",        # Indicates that this issue has a significant impact.
      "Minor" => "Normal",      # Indicates that this issue has a relatively minor impact.
      "Trivial" => "Low",       # Lowest priority.
  }

FORMAT_TYPE_CUSTOM_FIELD_MARKER = "Not type"
DEFAULT_FORMAT_TYPE_CUSTOM_FIELD =
 {"com.atlassian.jira.plugin.system.customfieldtypes:multicheckboxes"=>"list",
 "com.atlassian.jira.plugin.system.customfieldtypes:labels"=>"string",
 "com.atlassian.jira.plugin.system.customfieldtypes:float"=>"float",
 "com.pyxis.greenhopper.jira:gh-sprint"=>"text",
 "com.pyxis.greenhopper.jira:gh-epic-label"=>"text",
 "com.pyxis.greenhopper.jira:gh-epic-status"=>"text",
 "com.pyxis.greenhopper.jira:gh-epic-color"=>"text",
 "com.pyxis.greenhopper.jira:gh-epic-link"=>"text",
 "com.pyxis.greenhopper.jira:gh-lexo-rank"=>"text",
 "com.atlassian.bonfire.plugin:bonfire-multi-session-cft"=>"string",
 "com.atlassian.bonfire.plugin:bonfire-session-cft"=>"string",
 "com.atlassian.bonfire.plugin:bonfire-testing-status-cft"=>"string",
 "com.atlassian.bonfire.plugin:bonfire-text"=>"text",
 "com.tempoplugin.tempo-teams:team.customfield"=>"string",
 "com.atlassian.jconnect.jconnect-plugin:uuid"=>"string",
 "com.atlassian.jconnect.jconnect-plugin:location"=>"string",
 "com.atlassian.jira.ext.charting:timeinstatus"=>"string",
 "com.atlassian.jira.ext.charting:firstresponsedate"=>"date",
 "com.atlassian.jira.plugin.system.customfieldtypes:textarea"=>"text",
 "com.atlassian.jira.plugin.system.customfieldtypes:datetime"=>"date",
 "com.atlassian.jira.plugin.system.customfieldtypes:datepicker"=>"date",
 "com.atlassian.jira.plugin.system.customfieldtypes:textfield"=>"string",
 "com.atlassian.jira.plugin.system.customfieldtypes:select"=>"list",
 "com.tempoplugin.tempo-accounts:accounts.customfield"=>"string",
 "com.tempoplugin.tempo-plan-core:tp.iteration.customfield"=>"string"}

  # Xml file holder
  $doc = nil

  # A dummy Redmine user to use in place of JIRA users who have been deleted.
  # This user is lazily migrated only if needed.
  $GHOST_USER = nil

  # Jira projects to ignore during import
  $IGNORED_PROJECTS = ['Demo', 'Test']

  # Mapping between Jira Issue Type and Jira Issue Type Id - key = Id, value = Type
  $MIGRATED_ISSUE_TYPES_BY_ID = {}
  # Mapping between Jira Issue Status and Jira Issue Status Id - key = Id, value = Status
  $MIGRATED_ISSUE_STATUS_BY_ID = {}
  # Mapping between Jira custom field and redmine Custom field  Id - key = Id, value = id
  $MAP_JIRA_CUSTOM_FIELD_ID_TO_REDMINE = {}
  $MAP_FIELD_ID_SELECT_OPTIONS = {}
  # Mapping between Jira Issue Priority and Jira Issue Priority Id - key = Id, value = Priority
  $MIGRATED_ISSUE_PRIORITIES_BY_ID = {}
  # Mapping between Jira Issue Type and Redmine Issue Type - key = Jira, value = Redmine
  $MIGRATED_ISSUE_TYPES = {}
  $MIGRATED_ISSUE_TYPE_IDS = []
  # Mapping between Jira Issue Status and Redmine Issue Status - key = Jira, value = Redmine
  $MIGRATED_ISSUE_STATUS = {}
  # Mapping between Jira Issue Priorities and Redmine Issue Priorities - key = Jira, value = Redmine
  $MIGRATED_ISSUE_PRIORITIES = {}

  # Migrated Users by Name.
  $MIGRATED_USERS_BY_NAME = {}

  # those maps are for parsing attachments optimisation. My jira xml was huge ~7MB, and parsing it for each attachment lasted for ever.
  # Now needed data are parsed once and put into those maps, which makes all things much faster.

  $MAP_ISSUE_TO_PROJECT_KEY = {}
  $MAP_PROJECT_ID_TO_PROJECT_KEY = {}


  # gets all mapping options
  def self.get_all_options()
    # return all options 
    # Issue Type, Issue Status, Issue Priority
    ret = {}
    ret["types"] = self.get_jira_issue_types()
    ret["status"] = self.get_jira_statuses()
    ret["priorities"] = self.get_jira_priorities()

    return ret
  end

  # Get or create Ghost (Dummy) user which will be used for jira issues if no corresponding user found
  def self.use_ghost_user
    ghost = User.find_by_login('deleted-user')
    if ghost.nil?
      puts "Creating ghost user to represent deleted JIRA users. Login name = deleted-user"
      ghost = User.new({  :firstname => 'Deleted',
                          :lastname => 'User',
                          :mail => 'deleted.user@example.com',
                          :password => 'deleteduser123' })
      ghost.login = 'deleted-user'
      ghost.lock # disable the user
      ghost.save!
      ghost.reload
    end
    $GHOST_USER = ghost
    ghost
  end

  def self.find_version_by_jira_id(jira_id)

  end

  def self.find_user_by_jira_name(jira_name)
    user = $MIGRATED_USERS_BY_NAME[jira_name]
    if user.nil?
      # User has not been migrated. Probably a user who has been deleted from JIRA.
      # Select or create the ghost user and use him instead.
      user = use_ghost_user
    end
    user
  end

  def self.get_list_from_tag(xpath_query)
    # Get a tag node and get all attributes as a hash
    ret = []
    # $doc.elements.each(xpath_query) {|node| ret.push(node.attributes.rehash)}
    $doc.xpath(xpath_query).each {|node|
      nm = node.attr("name")
      ret.push(Hash[node.attributes.map { |k,v| [k,v.content]}])}
      #ret.push(node.attributes.rehash)}

    return ret
  end

  def self.migrate_fixed_versions()

    path = "/*/NodeAssociation[@sourceNodeEntity=\"Issue\" and @sinkNodeEntity=\"Version\" and @associationType=\"IssueFixVersion\"]"
    associations = JiraMigration.get_list_from_tag(path)
    associations.each do |assoc|
      version = JiraVersion::MAP[assoc['sinkNodeId']]
      issue = JiraIssue::MAP[assoc['sourceNodeId']]
      issue.update_column(:fixed_version_id, version.id)
      issue.reload
    end
  end

  def self.migrate_membership()

    memberships = self.get_list_from_tag('/*/Membership[@membershipType="GROUP_USER"]')

    memberships.each do |m|
      user = User.find_by_login(m['lowerChildName'])
      if user.nil? or user == $GHOST_USER
        users = self.get_list_from_tag("/*/User[@lowerUserName=\"%s\"]" % m['lowerChildName'])
        if !users.nil? and !users.empty?
          user = User.find_by_mail(users[0]['emailAddress'])
        end
      end
      group = Group.find_by_lastname(m['lowerParentName'])
      if !user.nil? and !group.nil?
        if !group.users.exists?(user.id)
         group.users << user
        end
      end
    end

  end

  def self.migrate_issue_links()

    # Issue Link Types
    issue_link_types = self.get_list_from_tag('/*/IssueLinkType')
    # migrated_issue_link_types = {"jira issuelink type" => "redmine link type"}
    migrated_issue_link_types = {}
    issue_link_types.each do |linktype|
      migrated_issue_link_types[linktype['id']] = DEFAULT_ISSUELINK_TYPE_MAP.fetch(linktype['linkname'], ISSUELINK_TYPE_MARKER)
    end

    # Set Issue Links
    issue_links = self.get_list_from_tag('/*/IssueLink')
    issue_links.each do |link|
      linktype = migrated_issue_link_types[link['linktype']]
      issue_from = JiraIssue::MAP[link['source']]
      issue_to = JiraIssue::MAP[link['destination']]
      if linktype.downcase == 'subtask' or linktype.downcase == 'epic-story'
        #pp "Set Parent #{issue_from.id} to:", issue_to
        to_updated_on = issue_to.updated_on
        from_updated_on = issue_from.updated_on
        issue_to.update_attribute(:parent_issue_id, issue_from.id)
        issue_to.reload
        issue_to.update_column :updated_on, to_updated_on
        issue_from.update_column :updated_on, from_updated_on
        issue_to.reload
        issue_from.reload
      else
        #puts "========" + issue_from.id.inspect + "========" + linktype.inspect + "=========" + issue_to.id.inspect + "========="
        r = IssueRelation.new(:relation_type => linktype, :issue_from => issue_from, :issue_to => issue_to)
        if r.valid?
          r.save!
          r.reload
        else
          #puts "=====issue_from:" + issue_from.id.inspect + "====" + r.errors[:base].inspect + "=======issue_to:" + issue_to.id.inspect + "=========" 
        end        
      end
    end
  end

  def self.migrate_worktime()

    # Set Issue Links
    worklogs = self.get_list_from_tag('/*/Worklog')
    worklogs.each do |log|

      issue = JiraIssue::MAP[log['issue']]
      user = JiraMigration.find_user_by_jira_name(log['author'])
      TimeEntry.create!(:user => user, :issue_id => issue.id, :project_id => issue.project.id,
                        :hours => (log['timeworked'].to_s.empty? ? 0 : log['timeworked'].to_f / 3600),
                        :comments => log['body'].to_s.truncate(250, separator: ' '),
                        :spent_on => Time.parse(log['startdate']),
                        :created_on => Time.parse(log['created']),
                        :activity_id => TimeEntryActivity.find_by_name('Development').id)

    end
  end

  def self.get_jira_issue_types()
    # Issue Type
    issue_types = self.get_list_from_tag('/*/IssueType') 
    # migrated_issue_types = {"jira_type" => "redmine tracker"}
    migrated_issue_types = {}
    issue_types.each do |issue|
      issuename = issue["name"].gsub(':', '')
      migrated_issue_types[issuename] = DEFAULT_ISSUE_TYPE_MAP.fetch(issuename, ISSUE_TYPE_MARKER)
      $MIGRATED_ISSUE_TYPES_BY_ID[issue["id"]] = issue["name"]
    end
    return migrated_issue_types
  end

  def self.get_jira_statuses()
    # Issue Status
    issue_status = self.get_list_from_tag('/*/Status')
    # migrated_issue_status = {"jira_status" => "redmine status"}
    migrated_issue_status = {}
    issue_status.each do |issue|
      migrated_issue_status[issue["name"]] = DEFAULT_ISSUE_STATUS_MAP.fetch(issue["name"], ISSUE_STATUS_MARKER)
      $MIGRATED_ISSUE_STATUS_BY_ID[issue["id"]] = issue["name"]
    end
	  #puts migrated_issue_status.inspect
    return migrated_issue_status
  end

  def self.get_jira_priorities()
    # Issue Priority
    issue_priority = self.get_list_from_tag('/*/Priority')
    # migrated_issue_priority = {"jira_priortiy" => "redmine priority"}
    migrated_issue_priority = {}
    issue_priority.each do |issue|
      migrated_issue_priority[issue["name"]] = DEFAULT_ISSUE_PRIORITY_MAP.fetch(issue["name"], ISSUE_PRIORITY_MARKER)
      $MIGRATED_ISSUE_PRIORITIES_BY_ID[issue["id"]] = issue["name"]
    end
    return migrated_issue_priority
  end

  # Parse jira xml for Users and attributes and return new User record
  def self.parse_jira_users()
    users = []

    # For users in Redmine we need:
    # First Name, Last Name, E-mail, Password
    #<User id="110" directoryId="1" userName="userName" lowerUserName="username" active="1" createdDate="2013-08-14 13:07:57.734" updatedDate="2013-09-29 21:52:19.776" firstName="firstName" lowerFirstName="firstname" lastName="lastName" lowerLastName="lastname" displayName="User Name" lowerDisplayName="user name" emailAddress="user@mail.org" lowerEmailAddress="user@mail.org" credential="" externalId=""/>

    # $doc.elements.each('/*/User') do |node|
    $doc.xpath('/*/User').each do |node|
      if(node['emailAddress'].squish =~ /\A([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})\z/i)
        #if !node['firstName'].to_s.empty? and !node['lastName'].to_s.empty? and node['active'].to_s == '1'
          user = JiraUser.new(node)

          # Set user names (first name, last name)
          #user.jira_firstName = node["firstName"]
          #user.jira_lastName = node["lastName"]

          # Set email address
          user.jira_emailAddress = node["lowerEmailAddress"]

          user.jira_name = node["lowerUserName"]

          users.push(user)
          puts "Found JIRA user: #{user.jira_name}"
        #end
      end
    end

    return users
  end

  # Parse jira xml for Group and attributes and return new Group record
  def self.parse_jira_groups()

    groups = []

    #<Group id="30" groupName="developers" lowerGroupName="developers" active="1" local="0" createdDate="2011-05-08 15:47:01.492" updatedDate="2011-05-08 15:47:01.492" type="GROUP" directoryId="1"/>

    $doc.xpath('/*/Group').each do |node|
         group = JiraGroup.new(node)

          groups.push(group)
          pp 'Found JIRA group:',group.jira_lowerGroupName
    end
    return groups
  end

  def self.parse_projects()
    # PROJECTS:
    # for project we need (identifies, name and description)
    # in exported data we have name and key, in Redmine name and descr. will be equal
    # the key will be the identifier
    projs = []
    # $doc.elements.each('/*/Project') do |node|
    $doc.xpath('/*/Project').each do |node|
      proj = JiraProject.new(node)
      projs.push(proj)
    end

    migrated_projects = {}
    projs.each do |p|
      #puts "Name and descr.: #{p.red_name} and #{p.red_description}"
      #puts "identifier: #{p.red_identifier}"
      migrated_projects[p.jira_id] = p
    end
    #puts migrated_projects
    return projs
  end

  def self.parse_versions()
    ret = []
    # $doc.elements.each('/*/Action[@type="comment"]') do |node|
    $doc.xpath('/*/Version').each do |node|
      comment = JiraVersion.new(node)
      ret.push(comment)
    end
    return ret
  end

  def self.parse_issues()
    ret = []

    # $doc.elements.collect('/*/Issue'){|i|i}.sort{|a,b|a.attribute('key').to_s<=>b.attribute('key').to_s}.each do |node|
    $doc.xpath('/*/Issue').collect{|i|i}.sort{|a,b|a.attribute('key').to_s<=>b.attribute('key').to_s}.each do |node|
      issue = JiraIssue.new(node)
      ret.push(issue)
    end
    return ret
  end

  def self.parse_comments()
    ret = []
    # $doc.elements.each('/*/Action[@type="comment"]') do |node|
    $doc.xpath('/*/Action[@type="comment"]').each do |node|
      comment = JiraComment.new(node)
      ret.push(comment)
    end
    return ret
  end 

  def self.parse_attachments()
    attachs = []
    # $doc.elements.each('/*/FileAttachment') do |node|
    $doc.xpath('/*/FileAttachment').each do |node|
      attach = JiraAttachment.new(node)
      attachs.push(attach)
    end

    return attachs
  end
  
  def self.parse_customFields()
    customfields = []
    
    # $doc.elements.each('/*/FileAttachment') do |node|
    $doc.xpath('/*/CustomField').each do |node|
      customfield = JiraCustomField.new(node)
      customfields.push(customfield)
    end
    return customfields
  end
  
  def self.parse_customFieldValues()
    customfieldvalues = []
    
    # $doc.elements.each('/*/FileAttachment') do |node|
    $doc.xpath('/*/CustomFieldValue').each do |node|
      customfieldvalue = JiraCustomFieldValue.new(node)
      customfieldvalues.push(customfieldvalue)
    end
    return customfieldvalues
  end
end

namespace :jira_migration do

    task :load_xml => :environment do

      file = File.new(JiraMigration::ENTITIES_FILE, 'r:utf-8')
      # doc = REXML::Document.new(file)
      doc = Nokogiri::XML(file,nil,'utf-8')
      $doc = doc

      $MIGRATED_USERS_BY_NAME = Hash[User.all.map{|u|[u.login, u]}] #{} # Maps the Jira username to the Redmine Rails User object

      # $doc.elements.each("/*/Project") do |p|
      $doc.xpath("/*/Project").each do |p|
        $MAP_PROJECT_ID_TO_PROJECT_KEY[p['id']] = p['key']
      end

      #$doc.elements.each("/*/Issue") do |i|
      $doc.xpath("/*/Issue").each do |i|
        $MAP_ISSUE_TO_PROJECT_KEY[i["id"]] = { :project_key => $MAP_PROJECT_ID_TO_PROJECT_KEY[i["project"]], :issue_key => i['key']}
      end

    end

    desc "Generates the configuration for the map things from Jira to Redmine"
    task :generate_conf => [:environment, :load_xml] do
      conf_file = JiraMigration::CONF_FILE
      conf_exists = File.exists?(conf_file)
      if conf_exists
        puts "You already have a conf file"
        print "You want overwrite it ? [y/N] "
        overwrite = STDIN.gets.match(/^y$/i)
      end

      if !conf_exists or overwrite
        # Let's give the user all options to fill out
        options = JiraMigration.get_all_options()

        File.open(conf_file, "w"){ |f| f.write(options.to_yaml) }

        puts "This migration script needs the migration table to continue "
        puts "Please... fill the map table on the file: '#{conf_file}' and run again the script"
        puts "To start the options again, just remove the file '#{conf_file} and run again the script"
        exit(0)
      end
    end

    desc "Gets the configuration from YAML"
    task :pre_conf => [:environment, :load_xml] do

      conf_file = JiraMigration::CONF_FILE
      conf_exists = File.exists?(conf_file)

      if !conf_exists
        Rake::Task['jira_migration:generate_conf'].invoke
      end
      $confs = YAML.load_file(conf_file)
    end

    desc "Migrates Jira Users to Redmine Users"
    task :migrate_users => [:environment, :pre_conf] do
      users = JiraMigration.parse_jira_users()
      users.each do |u|
        #pp(u)
        user = User.find_by_mail(u.jira_emailAddress)
        if user.nil?
          new_user = u.migrate
          #new_user.update_attribute :must_change_passwd, true
        end
      end

      puts "Migrated Users"

    end

    desc "Migrates Jira Group to Redmine Group"
    task :migrate_groups => [:environment, :pre_conf] do
      groups = JiraMigration.get_list_from_tag('/*/Group')
      groups.each do |group|
        #pp(u)
        g = Group.find_by_lastname(group['lowerGroupName'])
        if g.nil?
          g = Group.new(lastname: group['lowerGroupName'])
        end
        g.save!
        g.reload
      end
      puts "Migrated Groups"

      JiraMigration.migrate_membership

      puts "Migrated Membership"

    end

    desc "Migrates Jira Issue Types to Redmine Trackes"
    task :migrate_issue_types => [:environment, :pre_conf] do

      JiraMigration.get_jira_issue_types()
      types = $confs["types"]
      types.each do |key, value|
        t = Tracker.find_by_name(value)
        if t.nil?
          t = Tracker.new(name: value)
        end
        t.save!
        t.reload
        $MIGRATED_ISSUE_TYPES[key] = t
                
      end
      puts "Migrated issue types"
    end

    desc "Migrates Jira Issue Status to Redmine Status"
    task :migrate_issue_status => [:environment, :pre_conf] do
      JiraMigration.get_jira_statuses()
      status = $confs["status"]
      status.each do |key, value|
        s = IssueStatus.find_by_name(value)
        if s.nil?
          s = IssueStatus.new(name: value)
        end
        s.save!
        s.reload        
        $MIGRATED_ISSUE_STATUS[key] = s
      end
      puts "Migrated issue status"
    end

    desc "Migrates Jira Issue Priorities to Redmine Priorities"
    task :migrate_issue_priorities => [:environment, :pre_conf] do
      JiraMigration.get_jira_priorities()
      priorities = $confs["priorities"]

      priorities.each do |key, value|
        p = IssuePriority.find_by_name(value)
        if p.nil?
          p = IssuePriority.new(name: value)
          p.save!
          p.reload
        end
        $MIGRATED_ISSUE_PRIORITIES[key] = p
      end
      puts "Migrated issue priorities"
    end

    desc "Migrates Jira Projects to Redmine Projects"
    task :migrate_projects => :environment do
      projects = JiraMigration.parse_projects()
      projects.reject!{|project|$IGNORED_PROJECTS.include?(project.red_name)}
      projects.each do |p|
        p.migrate
      end
    end

    desc "Migrates Jira Versions to Redmine Versions"
    task :migrate_versions => :environment do
      versions = JiraMigration.parse_versions()
      versions.reject!{|version|version.red_project.nil?}
      versions.each do |i|
        i.migrate
      end
    end

    desc "Migrates Jira Issues to Redmine Issues"
    task :migrate_issues => :environment do
      issues = JiraMigration.parse_issues()
      issues.reject!{|issue|issue.red_project.nil?}
      issues.each do |i|
        i.migrate
      end

      JiraMigration.migrate_fixed_versions
      JiraMigration.migrate_issue_links
      JiraMigration.migrate_worktime

    end

    desc "Migrates Jira Issues Comments to Redmine Issues Journals (Notes)"
    task :migrate_comments => :environment do
      comments = JiraMigration.parse_comments()
      comments.reject!{|comment|comment.red_journalized.nil?}
      comments.each do |c|
        #pp(c)
        c.migrate
      end
    end

    desc "Migrates Jira Issues Attachments to Redmine Attachments"
    task :migrate_attachments => :environment do
      attachs = JiraMigration.parse_attachments()
      #attachs.reject!{|attach|attach.red_container.nil?}
      attachs.each do |a|
        #pp(a)
        a.migrate
      end
    end
    
    desc "Migrates Jira Custom_Field to Redmine Custom Field"
    task :migrate_custom_fields => :environment do
      customfields = JiraMigration.parse_customFields()
      customfields.each do |c|
        #pp(c)
        record = c.migrate
        $MAP_JIRA_CUSTOM_FIELD_ID_TO_REDMINE[c.jira_id]= record[:id]
      end
      # migrate custom field value
      #pp($MAP_JIRA_CUSTOM_FIELD_ID_TO_dREDMINE)
      #pp($MAP_FIELD_ID_SELECT_OPTIONS)
      customfieldvalues = JiraMigration.parse_customFieldValues()
      customfieldvalues.each do |cfv|
       #pp(cfv)
       cfv.migrate        
      end      
    end


    ##################################### Tests ##########################################
    desc "Just pretty print Jira Projects on screen"
    task :test_parse_projects => :environment do
      projects = JiraMigration.parse_projects()
      projects.each {|p| pp(p.run_all_redmine_fields) }
    end

    desc "Just pretty print Jira Users on screen"
    task :test_parse_users => [:environment,:pre_conf] do
      users = JiraMigration.parse_jira_users()
      users.each {|u| pp( u.run_all_redmine_fields) }
    end

    desc "Just pretty print Jira Comments on screen"
    task :test_parse_comments => :environment do
      comments = JiraMigration.parse_comments()
      comments.each {|c| pp( c.run_all_redmine_fields) }
    end

    desc "Just pretty print Jira Issues on screen"
    task :test_parse_issues => :environment do
      issues = JiraMigration.parse_issues()
      issues.each {|i| pp( i.run_all_redmine_fields) }
    end

    ##################################### Running all tests ##########################################
    desc "Tests all parsers!"
    task :test_all_migrations => [:environment, :pre_conf,
                                  :test_parse_projects,
                                  :test_parse_users,
                                  :test_parse_comments,
                                  :test_parse_issues] do
      puts "All parsers was run! :-)"
    end

    ##################################### Running all tasks ##########################################
    desc "Run all parsers!"
    task :do_all_migrations => [:environment, :pre_conf,
                                :migrate_issue_types,
                                :migrate_issue_status,
                                :migrate_issue_priorities,
                                :migrate_projects,
                                :migrate_versions,
                                :migrate_users,
                                :migrate_groups,
                                :migrate_issues,
                                :migrate_comments,
                                :migrate_attachments,
                                :migrate_custom_fields] do
      puts "All migrations done! :-)"
    end

  end
