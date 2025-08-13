#!/usr/bin/env bash
if [ -n "${DEBUG_SCRIPT:-}" ]; then
  set -x
fi
#set -eu -o pipefail
cd $APP_ROOT

LOG_FILE="logs/init-$(date +%F-%T).log"
exec > >(tee $LOG_FILE) 2>&1

TIMEFORMAT=%lR
# For faster performance, don't audit dependencies automatically.
export COMPOSER_NO_AUDIT=1
# For faster performance, don't install dev dependencies.
export COMPOSER_NO_DEV=1

# Install VSCode Extensions
if [ -n "${DP_VSCODE_EXTENSIONS:-}" ]; then
  IFS=','
  for value in $DP_VSCODE_EXTENSIONS; do
    time code-server --install-extension $value
  done
fi

#== Remove root-owned files.
echo
echo Remove root-owned files.
time sudo rm -rf lost+found

#== Composer install.
echo
if [ -f composer.json ]; then
  if composer show --locked cweagans/composer-patches ^2 &> /dev/null; then
    echo 'Update patches.lock.json.'
    time composer prl
    echo
  fi
else
  echo 'Generate composer.json.'
  time source .devpanel/composer_setup.sh
  echo
fi
# If update fails, change it to install.
time composer -n install --no-dev --no-progress

#== Create the private files directory.
if [ ! -d private ]; then
  echo
  echo 'Create the private files directory.'
  time mkdir private
fi

#== Create the config sync directory.
if [ ! -d config/sync ]; then
  echo
  echo 'Create the config sync directory.'
  time mkdir -p config/sync
fi

#== Generate hash salt.
if [ ! -f .devpanel/salt.txt ]; then
  echo
  echo 'Generate hash salt.'
  time openssl rand -hex 32 > .devpanel/salt.txt
fi

#== Install Drupal.
echo
if [ -z "$(drush status --field=db-status)" ]; then
  echo 'Install Drupal.'
  time drush -n si minimal

  # reset site UUID to what's in the new database
  config_file="config/sync/system.site.yml"
  
  # Check if the config file exists
  if [ ! -f "$config_file" ]; then
      echo "Error: Config file not found: $config_file"
      exit 1
  fi
  
  # Get the current site UUID using drush
  echo "Getting current site UUID..."
  current_uuid=$(drush cget system.site uuid --format=string)
  
  echo "Current site UUID: $current_uuid"

  # Get the UUID from the config file
  config_uuid=$(grep "^uuid:" "$config_file" | sed 's/uuid: //')
  echo "Config file UUID: $config_uuid"

  # Check if UUIDs are already the same
  if [ "$current_uuid" = "$config_uuid" ]; then
      echo "UUIDs already match. No changes needed."
  else
    # Create a backup of the original file
    cp "$config_file" "${config_file}.backup"
    echo "Created backup: ${config_file}.backup"
  
    # Replace the UUID in the config file
    sed -i.tmp "s/^uuid: .*/uuid: $current_uuid/" "$config_file"
    rm "${config_file}.tmp"
  
    echo "Updated UUID in $config_file"
    echo "Old UUID: $config_uuid"
    echo "New UUID: $current_uuid"
  
    # Verify the change
    new_config_uuid=$(grep "^uuid:" "$config_file" | sed 's/uuid: //')
    if [ "$new_config_uuid" = "$current_uuid" ]; then
        echo "✓ UUID successfully updated in config file"
    else
        echo "✗ Error: UUID update failed"
        exit 1
    fi
  fi

  # The config_split module requires multiple import runs to fully process configuration splits:
  drush cr
  drush cim -y
  drush cr
  drush cim -y
  drush cr
  drush cim -y

  # compile theme
  cd web/themes/custom/uswds_extend_custom
  npm run build
  cd -

  # install sample content
  drush en -y govcsm_sample_content
else
  echo 'Update database.'
  time drush -n updb
fi

#== Warm up caches.
echo
echo 'Run cron.'
time drush cron
echo
echo 'Populate caches.'
time drush cache:warm &> /dev/null || :
time .devpanel/warm

#== Finish measuring script time.
INIT_DURATION=$SECONDS
INIT_HOURS=$(($INIT_DURATION / 3600))
INIT_MINUTES=$(($INIT_DURATION % 3600 / 60))
INIT_SECONDS=$(($INIT_DURATION % 60))
printf "\nTotal elapsed time: %d:%02d:%02d\n" $INIT_HOURS $INIT_MINUTES $INIT_SECONDS
