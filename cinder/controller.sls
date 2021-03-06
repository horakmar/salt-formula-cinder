{%- from "cinder/map.jinja" import controller with context %}

{%- if controller.get('enabled', False) %}

include:
  {%- if controller.version not in ['mitaka','newton'] %}
  - apache
  {%- endif %}
  - cinder.db.offline_sync
  - cinder._ssl.controller_mysql
  - cinder._ssl.rabbitmq

{%- set user = controller %}
{%- include "cinder/user.sls" %}

{%- if controller.version not in ["juno", "kilo", "liberty", "mitaka", "newton", "ocata", "pike"] %}
  {%- do controller.pkgs.remove('cinder-api') %}
{%- endif %}

cinder_controller_packages:
  pkg.installed:
  - names: {{ controller.pkgs }}
  - require_in:
    - sls: cinder._ssl.controller_mysql
    - sls: cinder._ssl.rabbitmq
    - sls: cinder.db.offline_sync

/etc/cinder/cinder.conf:
  file.managed:
  - source: salt://cinder/files/{{ controller.version }}/cinder.conf.controller.{{ grains.os_family }}
  - template: jinja
  - mode: 0640
  - user: root
  - group: cinder
  - require:
    - pkg: cinder_controller_packages
    - sls: cinder._ssl.controller_mysql
    - sls: cinder._ssl.rabbitmq
  - require_in:
    - sls: cinder.db.offline_sync

/etc/cinder/api-paste.ini:
  file.managed:
  - source: salt://cinder/files/{{ controller.version }}/api-paste.ini.controller.{{ grains.os_family }}
  - template: jinja
  - mode: 0640
  - group: cinder
  - require:
    - pkg: cinder_controller_packages
    - sls: cinder._ssl.controller_mysql
    - sls: cinder._ssl.rabbitmq
  - require_in:
    - sls: cinder.db.offline_sync

{%- if controller.backup.engine != None %}
  {%- set cinder_log_services = controller.services + controller.backup.services %}
{%- else %}
  {%- set cinder_log_services = controller.services %}
{%- endif %}

{%- if controller.version not in ('ocata','pike','queens') %}
  {%- do cinder_log_services.append('cinder-api') %}
{%- endif %}

{%- for service_name in cinder_log_services %}
{{ service_name }}_default:
  file.managed:
    - name: /etc/default/{{ service_name }}
    - source: salt://cinder/files/default
    - template: jinja
    - defaults:
        service_name: {{ service_name }}
        values: {{ controller }}
    - require:
      - pkg: cinder_controller_packages
{%- if controller.backup.engine != None %}
      - pkg: cinder_backup_packages
{%- endif %}
    - watch_in:
      - service: cinder_controller_services
{%- if controller.backup.engine != None %}
      - pkg: cinder_backup_services
{%- endif %}
{%- endfor %}

{% if controller.logging.log_appender %}

{%- if controller.logging.log_handlers.get('fluentd', {}).get('enabled', False) %}
cinder_controller_fluentd_logger_package:
  pkg.installed:
    - name: python-fluent-logger
{%- endif %}

cinder_general_logging_conf:
  file.managed:
    - name: /etc/cinder/logging.conf
    - source: salt://oslo_templates/files/logging/_logging.conf
    - template: jinja
    - mode: 0640
    - user: root
    - group: cinder
    - defaults:
        service_name: cinder
        _data: {{ controller.logging }}
    - require:
      - pkg: cinder_controller_packages
      - sls: cinder._ssl.controller_mysql
      - sls: cinder._ssl.rabbitmq
    - require_in:
      - sls: cinder.db.offline_sync
{%- if controller.logging.log_handlers.get('fluentd', {}).get('enabled', False) %}
      - pkg: cinder_controller_fluentd_logger_package
{%- endif %}
    - watch_in:
      - service: cinder_controller_services
      - service: cinder_api_service

/var/log/cinder/cinder.log:
  file.managed:
    - user: cinder
    - group: cinder
    - watch_in:
      - service: cinder_controller_services
      - service: cinder_api_service

{% for service_name in cinder_log_services %}
{{ service_name }}_logging_conf:
  file.managed:
    - name: /etc/cinder/logging/logging-{{ service_name }}.conf
    - source: salt://oslo_templates/files/logging/_logging.conf
    - template: jinja
    - makedirs: True
    - mode: 0640
    - user: root
    - group: cinder
    - defaults:
        service_name: {{ service_name }}
        _data: {{ controller.logging }}
    - require:
      - pkg: cinder_controller_packages
{%- if controller.logging.log_handlers.get('fluentd', {}).get('enabled', False) %}
      - pkg: cinder_controller_fluentd_logger_package
{%- endif %}
{%- if controller.backup.engine != None %}
      - pkg: cinder_backup_packages
{%- endif %}
    - watch_in:
      - service: cinder_controller_services
{%- if controller.backup.engine != None %}
      - pkg: cinder_backup_services
{%- endif %}
{% endfor %}

{% endif %}

{%- for name, rule in controller.get('policy', {}).items() %}

{%- if rule != None %}
cinder_keystone_rule_{{ name }}_present:
  keystone_policy.rule_present:
  - path: /etc/cinder/policy.json
  - name: {{ name }}
  - rule: {{ rule }}
  - require:
    - pkg: cinder_controller_packages

{%- else %}

cinder_keystone_rule_{{ name }}_absent:
  keystone_policy.rule_absent:
  - path: /etc/cinder/policy.json
  - name: {{ name }}
  - require:
    - pkg: cinder_controller_packages

{%- endif %}

{%- endfor %}

{%- if controller.version not in ['mitaka','newton'] %}
{#- Creation of sites using templates is deprecated, sites should be generated by apache pillar, and enabled by cinder formula #}
{%- if pillar.get('apache', {}).get('server', {}).get('site', {}).cinder is not defined %}

cinder_apache_conf_file:
  file.managed:
  - name: /etc/apache2/conf-available/cinder-wsgi.conf
  - source: salt://cinder/files/{{ controller.version }}/cinder-wsgi.conf
  - template: jinja
  - require:
    - pkg: cinder_controller_packages

apache_enable_cinder_wsgi:
  apache_conf.enabled:
    - name: cinder-wsgi
    - require:
      - cinder_apache_conf_file

{%- else %}

cleanup_configs:
  file.absent:
    - names: ['/etc/apache2/conf-available/cinder-wsgi.conf', '/etc/apache2/conf-enabled/cinder-wsgi.conf']

cinder_apache_conf_file:
  file.exists:
  - name: /etc/apache2/sites-available/wsgi_cinder.conf
  - require:
    - pkg: cinder_controller_packages
    - cleanup_configs

apache_enable_cinder_wsgi:
  apache_site.enabled:
    - name: wsgi_cinder
    - require:
      - cinder_apache_conf_file

{%- endif %}

cinder_api_service_dead:
  service.dead:
    - name: cinder-api
    - enable: False
    - require:
      - pkg: cinder_controller_packages

cinder_api_service:
  service.running:
  - name: apache2
  - enable: true
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}
  - require:
    - pkg: cinder_controller_packages
    - service: cinder_api_service_dead
    - sls: cinder.db.offline_sync
    - sls: cinder._ssl.controller_mysql
    - sls: cinder._ssl.rabbitmq
  - watch:
    {%- if controller.message_queue.get('ssl',{}).get('enabled', False) %}
    - file: rabbitmq_ca_cinder_controller
    {%- endif %}
    - file: /etc/cinder/cinder.conf
    - file: /etc/cinder/api-paste.ini
    - cinder_apache_conf_file
    - apache_enable_cinder_wsgi

{%- else %}

cinder_api_service:
  service.running:
  - name: cinder-api
  - enable: true
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}
  - require:
    - pkg: cinder_controller_packages
    - sls: cinder.db.offline_sync
    - sls: cinder._ssl.controller_mysql
    - sls: cinder._ssl.rabbitmq
  - watch:
    {%- if controller.message_queue.get('ssl',{}).get('enabled', False) %}
    - file: rabbitmq_ca_cinder_controller
    {%- endif %}
    - file: /etc/cinder/cinder.conf
    - file: /etc/cinder/api-paste.ini

{%- endif %}


{%- if grains.get('virtual_subtype', None) == "Docker" %}

cinder_entrypoint:
  file.managed:
  - name: /entrypoint.sh
  - template: jinja
  - source: salt://cinder/files/entrypoint.sh
  - mode: 755

{%- endif %}

cinder_controller_services:
  service.running:
  - names: {{ controller.services }}
  - enable: true
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}
  - require:
    - pkg: cinder_controller_packages
    - sls: cinder.db.offline_sync
    - sls: cinder._ssl.controller_mysql
    - sls: cinder._ssl.rabbitmq
  - watch:
    {%- if controller.message_queue.get('ssl',{}).get('enabled', False) %}
    - file: rabbitmq_ca_cinder_controller
    {%- endif %}
    - file: /etc/cinder/cinder.conf
    - file: /etc/cinder/api-paste.ini

{%- if not grains.get('noservices', False) %}

{%- set identity = controller.identity %}

{#- Keystone V3 is supported only from Ocata release (https://docs.openstack.org/releasenotes/python-cinderclient/ocata.html) #}
{#- Therefore if api_version is not defined and OpenStack version is mitaka or newton use v2.0. #}
{%- if 'api_version' in identity %}
{%- set keystone_api_version = identity.get('api_version') %}
{%- else %} 
{%- if 'version' in controller and controller.version in ['mitaka', 'newton'] %}
{%- set keystone_api_version = 'v2.0' %}
{%- else %}
{%- set keystone_api_version = 'v3' %}
{%- endif %}
{%- endif %}

{%- set credentials = {'host': identity.host,
                       'user': identity.user,
                       'password': identity.password,
                       'project_id': identity.tenant,
                       'port': identity.get('port', 35357),
                       'protocol': identity.get('protocol', 'http'),
                       'region_name': identity.get('region', 'RegionOne'),
                       'endpoint_type': identity.get('endpoint_type', 'internalURL'),
                       'certificate': identity.get('certificate', controller.cacert_file),
                       'api_version': keystone_api_version} %}

{%- for backend_name, backend in controller.get('backend', {}).items() %}

{%- if backend.engine is defined and backend.engine == 'nfs' or (backend.engine == 'netapp' and backend.storage_protocol == 'nfs') %}
/etc/cinder/nfs_shares_{{ backend_name }}:
  file.managed:
  - source: salt://cinder/files/{{ controller.version }}/nfs_shares
  - defaults:
      backend: {{ backend|yaml }}
  - template: jinja
  - mode: 0640
  - group: cinder
  - require:
    - pkg: cinder_controller_packages

cinder_netapp_packages:
  pkg.installed:
    - pkgs:
      - nfs-common

{%- endif %}

{%- if backend.get('engine') == 'gpfs' %}
cinder_gpfs_mount_point_base_dir:
  file.directory:
  - name: {{ backend.get('mount_point') }}
  - mode: 0755
  - user: cinder
  - group: cinder
  - makedirs: True
{%- endif %}

{%- if backend.get('use_multipath_for_image_xfer', False) %}

cinder_netapp_add_packages:
  pkg.installed:
    - pkgs:
      - multipath-tools

{%- endif %}

cinder_type_create_{{ backend_name }}:
  cinderv3.volume_type_present:
  - name: {{ backend.type_name }}
  - cloud_name: admin_identity
  {%- if controller.get('role', 'primary') == 'secondary' %}
  - onlyif: /bin/false
  {%- endif %}
  - require:
    - service: cinder_controller_services

cinder_type_update_{{ backend_name }}:
  cinderv3.volume_type_key_present:
  - name: {{ backend.type_name }}
  - key: volume_backend_name
  - value: {{ backend_name }}
  - cloud_name: admin_identity
  {%- if controller.get('role', 'primary') == 'secondary' %}
  - onlyif: /bin/false
  {%- endif %}
  - require:
    - cinderv3: cinder_type_create_{{ backend_name }}

{%- endfor %}

{%- endif %}

{%- if controller.backup.engine != None %}

cinder_backup_packages:
  pkg.installed:
  - names: {{ controller.backup.pkgs }}

cinder_backup_services:
  service.running:
  - names: {{ controller.backup.services }}
  - enable: true
  - watch:
    {%- if controller.message_queue.get('ssl',{}).get('enabled', False) %}
    - file: rabbitmq_ca_cinder_controller
    {%- endif %}
    - file: /etc/cinder/cinder.conf
    - file: /etc/cinder/api-paste.ini

{%- endif %}

{%- if controller.message_queue.get('ssl',{}).get('enabled', False) %}
rabbitmq_ca_cinder_controller:
{%- if controller.message_queue.ssl.cacert is defined %}
  file.managed:
    - name: {{ controller.message_queue.ssl.cacert_file }}
    - contents_pillar: cinder:controller:message_queue:ssl:cacert
    - mode: 0444
    - makedirs: true
{%- else %}
  file.exists:
   - name: {{ controller.message_queue.ssl.get('cacert_file', controller.cacert_file) }}
{%- endif %}
{%- endif %}

{%- endif %}
