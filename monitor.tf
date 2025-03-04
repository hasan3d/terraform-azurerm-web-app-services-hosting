resource "azurerm_application_insights" "web_app_service" {
  name                = "${local.resource_prefix}-insights"
  location            = local.resource_group.location
  resource_group_name = local.resource_group.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.web_app_service.id
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "web_app_service" {
  name                       = "${local.resource_prefix}-webappservice"
  target_resource_id         = local.service_app.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.web_app_service.id

  dynamic "enabled_log" {
    for_each = local.service_diagnostic_setting_types
    content {
      category = enabled_log.value

      retention_policy {
        enabled = true
        days    = local.service_log_retention
      }
    }
  }

  metric {
    category = "AllMetrics"

    retention_policy {
      enabled = true
      days    = local.service_log_retention
    }
  }
}

resource "azurerm_application_insights_standard_web_test" "web_app_service" {
  count = local.enable_monitoring ? 1 : 0

  name                    = "${local.resource_prefix}-http"
  resource_group_name     = local.resource_group.name
  location                = local.resource_group.location
  application_insights_id = azurerm_application_insights.web_app_service.id
  timeout                 = 10
  description             = "Regional HTTP availability check"
  enabled                 = true

  geo_locations = [
    "emea-se-sto-edge", # UK West
    "emea-nl-ams-azr",  # West Europe
    "emea-ru-msa-edge"  # UK South
  ]

  request {
    url = local.monitor_http_availability_url

    header {
      name  = "X-AppInsights-HttpTest"
      value = azurerm_application_insights.web_app_service.name
    }
  }

  tags = merge(
    local.tags,
    { "hidden-link:${azurerm_application_insights.web_app_service.id}" = "Resource" },
  )
}

resource "azurerm_monitor_action_group" "web_app_service" {
  count = local.enable_monitoring ? 1 : 0

  name                = "${local.resource_prefix}-actiongroup"
  resource_group_name = local.resource_group.name
  short_name          = substr(local.project_name, 0, 12)
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = local.monitor_email_receivers

    content {
      name                    = "Email ${email_receiver.value}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  dynamic "logic_app_receiver" {
    for_each = length(azurerm_logic_app_workflow.webhook[0].id) > 0 ? [0] : []

    content {
      name                    = "Logic App"
      resource_id             = azurerm_logic_app_workflow.webhook[0].id
      callback_url            = azurerm_logic_app_trigger_http_request.webhook[0].callback_url
      use_common_alert_schema = true
    }
  }
}

resource "azurerm_monitor_metric_alert" "cpu" {
  count = local.enable_monitoring ? 1 : 0

  name                = "${local.resource_prefix}-cpu"
  resource_group_name = local.resource_group.name
  scopes              = [azurerm_service_plan.default.id]
  description         = "Action will be triggered when CPU usage is higher than 80% for longer than 5 minutes"
  window_size         = "PT5M"
  frequency           = "PT5M"
  severity            = 2

  criteria {
    metric_namespace = "microsoft.web/serverfarms"
    metric_name      = "CpuPercentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.web_app_service[0].id
  }

  tags = local.tags
}

resource "azurerm_monitor_metric_alert" "memory" {
  count = local.enable_monitoring ? 1 : 0

  name                = "${local.resource_prefix}-memory"
  resource_group_name = local.resource_group.name
  scopes              = [azurerm_service_plan.default.id]
  description         = "Action will be triggered when memory usage is higher than 80% for longer than 5 minutes"
  window_size         = "PT5M"
  frequency           = "PT5M"
  severity            = 2

  criteria {
    metric_namespace = "microsoft.web/serverfarms"
    metric_name      = "MemoryPercentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.web_app_service[0].id
  }

  tags = local.tags
}

resource "azurerm_monitor_metric_alert" "http" {
  count = local.enable_monitoring ? 1 : 0

  name                = "${local.resource_prefix}-http"
  resource_group_name = local.resource_group.name
  # Scope requires web test to come first
  # https://github.com/hashicorp/terraform-provider-azurerm/issues/8551
  scopes      = [azurerm_application_insights_standard_web_test.web_app_service[0].id, azurerm_application_insights.web_app_service.id]
  description = "Action will be triggered when regional availability becomes impacted."
  severity    = 2

  application_insights_web_test_location_availability_criteria {
    web_test_id           = azurerm_application_insights_standard_web_test.web_app_service[0].id
    component_id          = azurerm_application_insights.web_app_service.id
    failed_location_count = 2 # 2 out of 3 locations
  }

  action {
    action_group_id = azurerm_monitor_action_group.web_app_service[0].id
  }

  tags = local.tags
}

resource "azurerm_monitor_metric_alert" "latency" {
  count = local.enable_monitoring && local.enable_cdn_frontdoor ? 1 : 0

  name                = "${azurerm_cdn_frontdoor_profile.cdn[0].name}-latency"
  resource_group_name = local.resource_group.name
  scopes              = [azurerm_cdn_frontdoor_profile.cdn[0].id]
  description         = "Action will be triggered when Origin latency is higher than 1s"
  window_size         = "PT5M"
  frequency           = "PT5M"
  severity            = 2

  criteria {
    metric_namespace = "Microsoft.Cdn/profiles"
    metric_name      = "TotalLatency"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 1000
  }

  action {
    action_group_id = azurerm_monitor_action_group.web_app_service[0].id
  }

  tags = local.tags
}
