# Migrate-Jira2Redmine
Configuration before run script migrate:
1. Change length table name: issue_status, tracker, custom_field to 50 in file issue_status.rb, tracker.rb, custom_field.rb and db
2. Setting Upload file max-size on redmine: 6.000.000kb Administrator-> Setting-> Maximum attachments size / OR edit table setting, file setting.yml
3. Setting path data attachments:/home/redmine/JIRA-backup-20150303. Move all file in folder 100 to out folder 100.

# rake jira_migration:test_all_migrations RAILS_ENV="production"# Tests all parsers!
# rake jira_migration:do_all_migrations RAILS_ENV="production"
