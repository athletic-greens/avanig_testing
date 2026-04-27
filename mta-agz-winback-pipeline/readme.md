
feat: add MTA AGZ/Winback Markov attribution pipeline

- Refactored notebook removes local sql_config helpers, receives
  SQL_CONFIG/START_DATE/RUN_DATE/ENV via papermill params
- Writes output to /opt/ml/processing/output/markov_attrkeydaily_{RUN_DATE}.csv
  for pickup by prepare_merge_metadata → SchemaAwareMergeOperator
- Slack review outcomes notification via SLACK_WEBHOOK_URL env var
- Output table: PROD_EDG.RAW_ML_PLATFORM.MTA_AGZ_WINBACK_DAILY_ATTRIBUTION_BY_UNIFIED_ATTRIBUTION_KEY
- Schedule: Mondays 11AM UTC (matches daily_campaign_level_markov cadence)

TODO before merging:
- Build + push Docker image to ECR: 147644673796.dkr.ecr.us-east-1.amazonaws.com/mta_agz_winback:latest
- Populate SLACK_WEBHOOK_URL in the yaml environment block
