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

  // 1. Fetch lead details from Meta Graph API (or handle sample dummy event from Meta console)
  let leadData: MetaLeadResponse;

  if (leadgenId === '444444444444' || leadgenId.startsWith('4444')) {
    console.log('Detected Meta sample/test leadgen ID:', leadgenId);
    leadData = {
      id: leadgenId,
      campaign_name: 'Meta Webhook Console Sample',
      form_name: 'Lead Ads Sample Form',
      field_data: [
        { name: 'full_name', values: ['Meta Sample Test Lead'] },
        { name: 'phone_number', values: ['+91 7907675024'] },
        { name: 'city', values: ['Kochi, Kerala'] },
        { name: 'service_required', values: ['Legal Consulting / Registration (Sample)'] },
      ],
    };
  } else {
    const leadUrl = `https://graph.facebook.com/${graphVersion}/${leadgenId}?access_token=${encodeURIComponent(accessToken)}`;
    const resp = await fetch(leadUrl);
    if (!resp.ok) {
      const errText = await resp.text();
      console.error(`Failed to fetch leadgen ${leadgenId} from Meta:`, errText);
      return;
    }

    leadData = (await resp.json()) as MetaLeadResponse;
  }
  console.log('Lead details processed:', JSON.stringify(leadData, null, 2));

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
      } else if (fieldKey.includes('phone') || fieldKey.includes('mobile') || fieldKey.includes('contact')) {
        phone = val;
      } else if (fieldKey.includes('email')) {
        email = val;
      } else if (fieldKey.includes('city') || fieldKey.includes('location') || fieldKey.includes('place') || fieldKey.includes('where')) {
        city = val;
      } else if (fieldKey.includes('starting') || fieldKey.includes('restaurant') || fieldKey.includes('hotel')) {
        workType = `Hotel / Restaurant (${val})`;
        responses.push(`${f.name}: ${val}`);
      } else if (fieldKey.includes('property') || fieldKey.includes('valuation')) {
        workType = `Property Valuation (${val})`;
        responses.push(`${f.name}: ${val}`);
      } else if (fieldKey.includes('service') || fieldKey.includes('work') || fieldKey.includes('requirement')) {
        workType = val;
        responses.push(`${f.name}: ${val}`);
      } else {
        responses.push(`${f.name}: ${val}`);
      }
    }
  }

  const campaign = leadData.campaign_name || '';
  if (!name) name = 'Meta Ad Lead';
  if (!workType) {
    if (campaign.toLowerCase().includes('hotel')) {
      workType = 'Hotel & Restaurant Consulting';
    } else if (campaign.toLowerCase().includes('valuation')) {
      workType = 'Property Valuation';
    } else {
      workType = 'Meta Lead Ad Inquiry';
    }
  }
  if (!city) city = 'Facebook/Instagram';

  const source = campaign ? `Meta Ads: ${campaign}` : 'Meta Lead Ads (Facebook/Instagram)';

  // Build notes string from extra responses or email
  const notesBuffer: string[] = [];
  if (email) notesBuffer.push(`Email: ${email}`);
  if (responses.length > 0) notesBuffer.push(...responses);
  if (leadgenId) notesBuffer.push(`Meta Lead ID: ${leadgenId}`);
  const notes = notesBuffer.join('\n').trim();

  // Deduplication check: Check if deal already exists by Meta Lead ID or 10-digit phone number
  const supabaseUrl = process.env.SUPABASE_URL || 'https://bzxtgiqjgfojblezdubd.supabase.co';
  const supabaseKey = process.env.SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJ6eHRnaXFqZ2ZvamJsZXpkdWJkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU3OTMxMzIsImV4cCI6MjA4MTM2OTEzMn0.E8IKI5PvnW9WoEX4EcXvcSVk0b74LGrrQhNhFX99Dxo';

  const cleanPhone = (phone || '').replace(/[^0-9]/g, '');
  const cleanPhone10 = cleanPhone.length >= 10 ? cleanPhone.slice(-10) : cleanPhone;

  let alreadyExists = false;
  try {
    const checkQuery = cleanPhone10
      ? `or=(register_no.eq.${encodeURIComponent(leadgenId)},contact_info.ilike.*${cleanPhone10}*)`
      : `register_no=eq.${encodeURIComponent(leadgenId)}`;
    const checkResp = await fetch(`${supabaseUrl}/rest/v1/deals?select=id,name,contact_info,register_no&${checkQuery}&limit=1`, {
      headers: {
        'apikey': supabaseKey,
        'Authorization': `Bearer ${supabaseKey}`,
      }
    });
    if (checkResp.ok) {
      const existing = (await checkResp.json()) as any[];
      if (Array.isArray(existing) && existing.length > 0) {
        alreadyExists = true;
        console.log(`🛡️ Webhook Deduplication: Meta Lead #${leadgenId} (${name} / ${phone}) already exists (ID: ${existing[0].id}). Skipping duplicate!`);
      }
    }
  } catch (checkErr) {
    console.warn('Error checking existing deal in Supabase:', checkErr);
  }

  if (alreadyExists) {
    console.log(`Duplicate leadgen ${leadgenId} ignored.`);
    return;
  }

  const dealId = String(Math.floor(Date.now() / 1000));
  const nowIso = new Date().toISOString();

  // 3A. Save into DynamoDB Deals table (if table name is bound)
  if (dealsTable) {
    try {
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
        register_no: leadgenId,
        registerNo: leadgenId,
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

  // 3B. Mirror to Supabase for disaster recovery & web dashboard visibility
  try {
    const dealRecord = {
      id: dealId,
      name: name,
      contact_info: phone,
      company: city,
      work_type: workType,
      stage: 'Created',
      pipeline: 'CRM',
      priority: 'High',
      responsible_id: 2,
      responsible_name: 'Jesna',
      amount: 0,
      currency: 'INR',
      description: notes,
      referred_by: source,
      register_no: leadgenId,
      created_at: nowIso.replace('Z', ''),
    };
    await fetch(`${supabaseUrl}/rest/v1/deals`, {
      method: 'POST',
      headers: {
        'apikey': supabaseKey,
        'Authorization': `Bearer ${supabaseKey}`,
        'Content-Type': 'application/json',
        'Prefer': 'return=minimal'
      },
      body: JSON.stringify(dealRecord)
    });
    console.log(`✅ Mirrored Meta Lead #${dealId} to Supabase!`);
  } catch (sbErr) {
    console.error('Error mirroring deal to Supabase:', sbErr);
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

  const istTimeStr = new Date().toLocaleString('en-IN', {
    timeZone: 'Asia/Kolkata',
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    hour12: true,
  });

  const lines = [
    '🎯 *New Meta Lead Alert!* (AWS Cloud 24/7)',
    '',
    `👤 *Name:* ${name}`,
    `📞 *Phone:* ${phone || 'N/A'}`,
  ];
  if (city) lines.push(`📍 *Location:* ${city}`);
  if (workType) lines.push(`📋 *Requirement:* ${workType}`);
  if (campaign) lines.push(`🏷️ *Campaign:* ${campaign}`);
  lines.push(`⏰ *Time:* ${istTimeStr} (IST)`);
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

      // 1. Send approved utility template (cuc_lead_alert) - Guaranteed 24/7 delivery to all admin numbers without 24h window
      const templateRes = await fetch(waUrl, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          messaging_product: 'whatsapp',
          recipient_type: 'individual',
          to: cleanPhone,
          type: 'template',
          template: {
            name: 'cuc_lead_alert',
            language: { code: 'en_US' },
            components: [
              {
                type: 'body',
                parameters: [
                  { type: 'text', text: name || 'New Lead' },
                  { type: 'text', text: phone || 'N/A' },
                  { type: 'text', text: city || 'Kerala' },
                  { type: 'text', text: workType || 'Legal / Business Consulting' },
                ],
              },
            ],
          },
        }),
      });

      const templateBody = await templateRes.text();
      if (templateRes.ok) {
        console.log(`✅ Approved template alert delivered to ${cleanPhone}:`, templateBody);
      } else {
        console.warn(`Template send returned:`, templateBody);
      }

      // 2. Also send the full detailed breakdown text
      await fetch(waUrl, {
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
    } catch (waErr) {
      console.error(`Error sending WhatsApp to ${cleanPhone}:`, waErr);
    }
  }
}
