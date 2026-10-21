import { defineFunction } from '@aws-amplify/backend';

export const metaWebhook = defineFunction({
  name: 'meta-webhook',
  entry: './handler.ts',
  timeoutSeconds: 30,
  environment: {
    META_ACCESS_TOKEN:
      'EAAbAi2KYeXcBS1nCfNqRxa6vM2PDliFwQ0jAIXCqUP9WRF8Oh8gx9AveihGNZCuGxUUcM9xro3x6KiEpirFu4t8iwAOzwZAZAdZCeJgkRnBxbVEOiCKXEfrczDzjktvnOxIG53slI1YBLk2pLiOZCDyZBygmM87ZCEZBeMKMZCd1C35Y7SfW3tfePidDE8qmCiQZDZD',
    META_VERIFY_TOKEN: 'cuc_meta_verify_token_2026',
    META_GRAPH_VERSION: 'v19.0',
    WHATSAPP_PHONE_ID: '979396128599210',
    NOTIFY_ADMIN_PHONE: '917012466754, 917907675024',
  },
});
