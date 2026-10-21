import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, PutCommand } from '@aws-sdk/lib-dynamodb';

declare const process: any;
declare const Buffer: any;

const ddbClient = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(ddbClient);

interface MetaFieldData {
  name: string;
  values: string[];
}

interface MetaLeadResponse {
  id: string;
  created_time?: string;
  field_data?: MetaFieldData[];
  campaign_name?: string;
  ad_name?: string;
  form_name?: string;
}

export const handler = async (event: any): Promise<any> => {
  console.log('Incoming Meta Webhook event:', JSON.stringify(event));

  const method = (event.requestContext?.http?.method || event.httpMethod || 'GET').toUpperCase();
  const query = event.queryStringParameters || {};

  // 1. Handle Meta Webhook Verification (GET request)
  if (method === 'GET') {
    const mode = query['hub.mode'];
    const token = query['hub.verify_token'];
    const challenge = query['hub.challenge'];
    const expectedToken = process.env.META_VERIFY_TOKEN || 'cuc_meta_verify_token_2026';

    if (mode === 'subscribe' && token === expectedToken) {
      console.log('✅ Meta Webhook challenge verified successfully:', challenge);
      return {
        statusCode: 200,
        headers: { 'Content-Type': 'text/plain' },
        body: challenge,
      };
    }

    console.warn('❌ Webhook token mismatch. Got:', token, 'expected:', expectedToken);
    return {
      statusCode: 403,
      body: 'Forbidden: Invalid verification token',
    };
  }

  // 2. Handle Meta Inbound Events (POST request)
  if (method === 'POST') {
    try {
      let rawBody = event.body || '{}';
      if (event.isBase64Encoded) {
        rawBody = Buffer.from(rawBody, 'base64').toString('utf-8');
      }

      const payload = typeof rawBody === 'string' ? JSON.parse(rawBody) : rawBody;
      console.log('Parsed Webhook Payload:', JSON.stringify(payload, null, 2));

      const accessToken = process.env.META_ACCESS_TOKEN;
      const graphVersion = process.env.META_GRAPH_VERSION || 'v19.0';
      const dealsTable = process.env.DEALS_TABLE_NAME;

      if (Array.isArray(payload.entry)) {
        for (const entry of payload.entry) {
          if (Array.isArray(entry.changes)) {
            for (const change of entry.changes) {
              // A. Handle Meta Lead Ads (leadgen)
              if (change.field === 'leadgen' && change.value?.leadgen_id) {
                const leadgenId = change.value.leadgen_id;
                console.log(`🎯 Processing Leadgen event for leadgen_id: ${leadgenId}`);

                await processMetaLead({
                  leadgenId,
                  accessToken,
                  graphVersion,
                  dealsTable,
                });
              }

              // B. Handle Inbound WhatsApp messages
              if (change.field === 'messages') {
                console.log('📩 WhatsApp messages change received:', JSON.stringify(change.value));
              }
            }
          }
        }
      }

      return {
        statusCode: 200,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: 'EVENT_RECEIVED' }),
      };
    } catch (err: any) {
      console.error('Error handling Meta Webhook POST:', err);
      // Return 200 so Meta doesn't retry endlessly on bad payloads
      return {
        statusCode: 200,
        body: JSON.stringify({ error: err.message }),
      };
    }
  }

  return {
    statusCode: 405,
    body: 'Method Not Allowed',
  };
};

/**
 * Fetch lead details from Meta Graph API, store in DynamoDB, and send WhatsApp alert
 */
async function processMetaLead({
  leadgenId,
  accessToken,
  graphVersion,
  dealsTable,
}: {
  leadgenId: string;
  accessToken?: string;
  graphVersion: string;
  dealsTable?: string;
}): Promise<void> {
  if (!accessToken) {
    console.error('META_ACCESS_TOKEN is not configured.');
    return;
  }

  // 1. Fetch lead details from Meta Graph API
  const leadUrl = `https://graph.facebook.com/${graphVersion}/${leadgenId}?access_token=${encodeURIComponent(accessToken)}`;
  const resp = await fetch(leadUrl);
  if (!resp.ok) {
    const errText = await resp.text();
    console.error(`Failed to fetch leadgen ${leadgenId} from Meta:`, errText);
    return;
  }

  const leadData = (await resp.json()) as MetaLeadResponse;
  console.log('Fetched lead details from Meta:', JSON.stringify(leadData, null, 2));

  // 2. Parse field_data
  let name = '';
  let phone = '';
  let email = '';
  let city = '';
  let workType = '';
  const responses: string[] = [];

  if (Array.isArray(leadData.field_data)) {
    for (const f of leadData.field_data) {
      const fieldKey = (f.name || '').toLowerCase().trim();
      const val = (f.values && f.values.length > 0) ? f.values[0] : '';
      if (!val) continue;

      if (fieldKey.includes('full_name') || fieldKey === 'name') {
        name = val;
      } else if (fieldKey.includes('phone')) {
        phone = val;
      } else if (fieldKey.includes('email')) {
        email = val;
      } else if (fieldKey.includes('city') || fieldKey.includes('location')) {
        city = val;
      } else if (fieldKey.includes('service') || fieldKey.includes('work') || fieldKey.includes('requirement')) {
        workType = val;
      } else {
        responses.push(`${f.name}: ${val}`);
      }
    }
  }

  if (!name) name = 'Meta Ad Lead';
  if (!workType) workType = 'Meta Lead Ad Inquiry';
  if (!city) city = 'Facebook/Instagram';

  const campaign = leadData.campaign_name || '';
  const source = campaign ? `Meta Ads: ${campaign}` : 'Meta Lead Ads (Facebook/Instagram)';

  // Build notes string from extra responses or email
  const notesBuffer: string[] = [];
  if (email) notesBuffer.push(`Email: ${email}`);
  if (responses.length > 0) notesBuffer.push(...responses);
  const notes = notesBuffer.join('\n').trim();

  // 3. Save into DynamoDB Deals table (if table name is bound)
  if (dealsTable) {
    try {
      const dealId = String(Math.floor(Date.now() / 1000));
      const nowIso = new Date().toISOString();

      const newDeal = {
        id: dealId,
        name: name,
        client_name: name,
        contact_info: phone,
        company: city,
        work_type: workType,
        stage: 'Created',
        pipeline: 'CRM',
        priority: 'High',
        referred_by: source,
        description: notes,
        amount: 0,
        currency: 'INR',
        is_won: false,
        created_at: nowIso,
        updated_at: nowIso,
        createdAt: nowIso,
        updatedAt: nowIso,
        __typename: 'Deals',
      };

      await docClient.send(
        new PutCommand({
          TableName: dealsTable,
          Item: newDeal,
        })
      );
      console.log(`✅ Saved Meta Lead #${dealId} into DynamoDB Deals table!`);
    } catch (dbErr) {
      console.error('Error saving deal to DynamoDB:', dbErr);
    }
  } else {
    console.warn('DEALS_TABLE_NAME not set; skipped DynamoDB insert.');
  }

  // 4. Send Instant WhatsApp Notification to Admin
  await sendAdminWhatsAppAlert({
    name,
    phone,
    city,
    workType,
    campaign,
    notes,
    accessToken,
    graphVersion,
  });
}

/**
 * Send WhatsApp alert using Meta WhatsApp Cloud API
 */
async function sendAdminWhatsAppAlert({
  name,
  phone,
  city,
  workType,
  campaign,
  notes,
  accessToken,
  graphVersion,
}: {
  name: string;
  phone: string;
  city: string;
  workType: string;
  campaign: string;
  notes: string;
  accessToken: string;
  graphVersion: string;
}): Promise<void> {
  const waPhoneId = process.env.WHATSAPP_PHONE_ID || '979396128599210';
  const adminPhonesRaw = process.env.NOTIFY_ADMIN_PHONE || '917012466754, 917907675024';

  const adminPhones = adminPhonesRaw
    .split(',')
    .map((p: string) => p.trim())
    .filter((p: string) => p.length > 0);

  const lines = [
    '🎯 *New Meta Lead Alert!* (AWS Cloud 24/7)',
    '',
    `👤 *Name:* ${name}`,
    `📞 *Phone:* ${phone || 'N/A'}`,
  ];
  if (city) lines.push(`📍 *Location:* ${city}`);
  if (workType) lines.push(`📋 *Requirement:* ${workType}`);
  if (campaign) lines.push(`🏷️ *Campaign:* ${campaign}`);
  if (notes) {
    lines.push('');
    lines.push(`📝 *Responses:*\n${notes}`);
  }
  lines.push('');
  lines.push('👉 *Cochin United Consultancy CRM*');

  const alertMessage = lines.join('\n');

  for (const rawPhone of adminPhones) {
    let cleanPhone = rawPhone.replace(/[^0-9]/g, '');
    if (cleanPhone.length === 10) cleanPhone = '91' + cleanPhone;

    console.log(`Sending WhatsApp alert to ${cleanPhone}...`);
    try {
      const waUrl = `https://graph.facebook.com/${graphVersion}/${waPhoneId}/messages`;
      const res = await fetch(waUrl, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          messaging_product: 'whatsapp',
          recipient_type: 'individual',
          to: cleanPhone,
          type: 'text',
          text: {
            preview_url: false,
            body: alertMessage,
          },
        }),
      });

      const resBody = await res.text();
      if (res.ok) {
        console.log(`✅ WhatsApp alert delivered to ${cleanPhone}:`, resBody);
      } else {
        console.error(`❌ Failed to send WhatsApp alert to ${cleanPhone}:`, resBody);
      }
    } catch (waErr) {
      console.error(`Error sending WhatsApp to ${cleanPhone}:`, waErr);
    }
  }
}
