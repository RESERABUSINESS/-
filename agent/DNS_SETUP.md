# سجلات DNS المطلوبة لـ getfatoorati.com (Resend)

أضفها عند مزوّد الدومين (Netlify / Namecheap / GoDaddy ...). بعد ما تنتشر، الوكيل يقدر يرسل من `hello@getfatoorati.com`.

| النوع | الاسم (Host) | القيمة | الأولوية |
|---|---|---|---|
| TXT | `resend._domainkey` | `p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC3rakRp0ywLgFWoCCPPVL5InQ4HZKORqletxgE5AWi8O2j5BRsFdYvP/3yjCAMmYys2U0yGYCxPlY7rqwHlcM3oBYCshKZ9i9xT+sOKwSaNBNRTwLdmvEQwxAtBJJq5Yv6FE9Wuu0sq0RfdYEK0LGGY8Cd845lI3W/YtBajE0nGQIDAQAB` | |
| MX | `send` | `feedback-smtp.us-east-1.amazonses.com` | 10 |
| TXT | `send` | `v=spf1 include:amazonses.com ~all` | |
| CNAME | `rsend` | `send.forge.rmta.net` | |

مستحسن كمان (يحسّن الوصول للصندوق الوارد):

| TXT | `_dmarc` | `v=DMARC1; p=none;` | |

بعد الإضافة اضغط **Verify** في لوحة Resend ← Domains، أو قل لـ Claude «تحقق من الدومين».
