This project is looking for a new maintainer
If you are interested in taking over, please contact me personally.

jira2redmine
============

Script for import from JIRA to redmine

for more information please look at: http://www.redmine.org/issues/1385

## How to

1. Copy `migrate_jira.rake` to `lib/tasks` in your *Redmine* directory and the execute the following:
2. Configuration before run script migrate:
  - Change length table name: issue_status, tracker, custom_field to 50 in file issue_status.rb, tracker.rb, custom_field.rb and db
  - Setting Upload file max-size on redmine: 6.000.000kb Administrator-> Setting-> Maximum attachments size / OR edit table setting, file setting.yml
  - Setting path data attachments:/home/redmine/JIRA-backup-20150303. Move all file in folder 100 to out folder 100.

```
rake jira_migration:test_all_migrations RAILS_ENV="production"
rake jira_migration:do_all_migrations RAILS_ENV="production"
```

