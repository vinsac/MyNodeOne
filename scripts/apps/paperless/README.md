# Paperless-ngx

**Document Management System with OCR**

Paperless-ngx is a powerful document management system that helps you scan, index, and archive all your physical documents digitally. It features automatic OCR (Optical Character Recognition), full-text search, and smart organization.

---

## Features

- 📄 **OCR Processing** - Automatically extract text from scanned documents
- 🔍 **Full-Text Search** - Find any document instantly
- 🏷️ **Smart Tagging** - Organize with tags, correspondents, and document types
- 📱 **Mobile Apps** - Scan and upload from your phone
- 📧 **Email Import** - Forward documents directly to Paperless
- 🗂️ **Automatic Filing** - Rules-based document organization
- 🔒 **Secure** - All documents encrypted at rest
- 🌐 **Web Interface** - Access from any browser

---

## Installation

### Quick Install

Run on your **control plane**:

```bash
sudo ./scripts/apps/paperless/install-paperless.sh
```

The script will:
1. ✅ Validate cluster prerequisites
2. 🌐 Configure subdomain (e.g., `paperless.mynodeone.local`)
3. 💾 Set up storage for documents and database
4. 🔐 Generate secure credentials
5. 🗄️ Deploy PostgreSQL database
6. 📮 Deploy Redis for task queue
7. 📄 Deploy Paperless-ngx application
8. 📝 Register service for DNS access

### What You'll Need

**Minimum Requirements:**
- 1GB RAM
- 1 CPU core
- 50Gi storage (for ~5,000 documents)

**Recommended:**
- 2GB RAM
- 2 CPU cores
- 100Gi+ storage

---

## First-Time Setup

### 1. Access Paperless

After installation, access at:
```
http://paperless.mynodeone.local
```

Login with the credentials shown during installation:
- **Username:** `admin`
- **Password:** (shown during install - save it!)

### 2. Configure Document Consumption

Paperless can receive documents in several ways:

#### **Option A: Web Upload**
1. Click "Upload" in the web interface
2. Drag and drop files or select from computer
3. Documents are automatically processed with OCR

#### **Option B: Mobile App**
1. Install "Paperless Mobile" from App Store or Play Store
2. Configure server URL: `http://paperless.mynodeone.local`
3. Login with your credentials
4. Use the app to scan and upload documents

#### **Option C: Email Import** (Advanced)
1. Go to Settings → Mail
2. Configure email consumption
3. Forward documents to your Paperless email address
4. They'll be automatically imported and processed

### 3. Organize Your Documents

**Set up Tags:**
- Go to Settings → Tags
- Create tags like: `tax`, `receipt`, `invoice`, `medical`, `insurance`

**Set up Correspondents:**
- Go to Settings → Correspondents
- Add people/companies: `IRS`, `Bank`, `Insurance Co`, etc.

**Set up Document Types:**
- Go to Settings → Document Types
- Create types: `Receipt`, `Invoice`, `Letter`, `Contract`, etc.

### 4. Create Matching Rules (Optional)

Automate document organization:
1. Go to Settings → Matching
2. Create rules to auto-assign tags, correspondents, types
3. Example: "If filename contains 'receipt' → tag as 'receipt'"

---

## Daily Usage

### Scanning Documents

**From Mobile:**
1. Open Paperless Mobile app
2. Tap camera icon
3. Scan document
4. Review and upload
5. Document is automatically OCR'd and indexed

**From Computer:**
1. Scan document to PDF or image
2. Upload via web interface
3. Add tags/correspondent if needed
4. Save

### Finding Documents

**Search:**
- Use the search bar for full-text search
- Search works on OCR'd text, not just filenames

**Filter:**
- Filter by tags, correspondents, document types
- Filter by date range
- Combine filters for precise results

**Browse:**
- View all documents in chronological order
- Click any document to view/download

---

## Storage Management

### Check Storage Usage

```bash
kubectl get pvc -n paperless
```

### Expand Storage

If you're running out of space:

```bash
# Edit the PVC
kubectl edit pvc paperless-data -n paperless

# Change the storage size, e.g., from 100Gi to 200Gi
# Save and exit
```

Longhorn will automatically expand the volume.

---

## Mobile Access

### Setup on Phone

1. **Install App:**
   - iOS: "Paperless Mobile" from App Store
   - Android: "Paperless Mobile" from Play Store

2. **Configure Server:**
   - Server URL: `http://paperless.mynodeone.local`
   - Username: `admin`
   - Password: (your admin password)

3. **Enable Tailscale** (for remote access):
   - Install Tailscale app
   - Login with same account as MyNodeOne
   - Now access Paperless from anywhere!

---

## Public Access (Optional)

To access Paperless from the internet:

```bash
sudo ./scripts/manage-app-visibility.sh
```

This will:
- Set up secure HTTPS with Let's Encrypt
- Configure VPS routing
- Make Paperless accessible at `https://paperless.yourdomain.com`

⚠️ **Security Note:** Paperless has built-in authentication, but ensure you use a strong admin password when making it public.

---

## Backup & Restore

### Export All Documents

1. Go to Settings → Export
2. Click "Export All Documents"
3. Download the ZIP file
4. Store safely (external drive, cloud backup, etc.)

### Backup Database

```bash
# Backup PostgreSQL database
kubectl exec -n paperless deployment/paperless-postgres -- \
  pg_dump -U paperless paperless > paperless-backup.sql
```

### Restore from Backup

1. Reinstall Paperless
2. Upload documents via web interface
3. Or restore database:

```bash
# Restore PostgreSQL database
kubectl exec -i -n paperless deployment/paperless-postgres -- \
  psql -U paperless paperless < paperless-backup.sql
```

---

## Troubleshooting

### Documents Not Processing

**Check consumer status:**
```bash
kubectl logs -n paperless deployment/paperless -f
```

Look for OCR processing logs.

**Restart Paperless:**
```bash
kubectl rollout restart deployment/paperless -n paperless
```

### Can't Access Web Interface

**Check if pods are running:**
```bash
kubectl get pods -n paperless
```

All pods should show `Running` status.

**Check service:**
```bash
kubectl get svc -n paperless
```

Should show LoadBalancer with an IP address.

### OCR Not Working

**Check OCR language:**
```bash
kubectl set env deployment/paperless -n paperless PAPERLESS_OCR_LANGUAGE=eng
```

For multiple languages:
```bash
kubectl set env deployment/paperless -n paperless PAPERLESS_OCR_LANGUAGE=eng+fra+deu
```

### Slow Performance

**Increase resources:**
```bash
kubectl edit deployment paperless -n paperless
```

Increase memory and CPU limits:
```yaml
resources:
  requests:
    memory: "2Gi"
    cpu: "1000m"
  limits:
    memory: "4Gi"
    cpu: "2000m"
```

---

## Uninstallation

### Keep Documents (Remove App Only)

```bash
sudo ./scripts/apps/paperless/uninstall-paperless.sh
```

Choose option 1 to keep your documents and database.

### Delete Everything

```bash
sudo ./scripts/apps/paperless/uninstall-paperless.sh
```

Choose option 2 to permanently delete all documents and data.

⚠️ **Warning:** This cannot be undone! Export your documents first.

---

## Advanced Configuration

### Change OCR Language

Edit deployment to add more languages:
```bash
kubectl set env deployment/paperless -n paperless \
  PAPERLESS_OCR_LANGUAGE=eng+spa+fra
```

Supported languages: eng, deu, fra, ita, spa, por, nld, rus, chi_sim, jpn, and more.

### Configure Email Consumption

1. Go to Settings → Mail in web interface
2. Enable mail consumption
3. Configure IMAP settings
4. Set up mail rules

### Customize Document Processing

Edit environment variables:
```bash
kubectl edit deployment paperless -n paperless
```

Common options:
- `PAPERLESS_OCR_MODE`: `skip`, `redo`, `force`
- `PAPERLESS_OCR_CLEAN`: `clean`, `none`
- `PAPERLESS_TIME_ZONE`: Your timezone

---

## Tips & Best Practices

### Document Naming

- Use descriptive filenames before uploading
- Paperless will preserve original filenames
- OCR text is searchable regardless of filename

### Tagging Strategy

- Use consistent tag names
- Create a tag hierarchy (e.g., `finance/tax`, `finance/receipt`)
- Don't over-tag - 3-5 tags per document is usually enough

### Regular Maintenance

- Export documents monthly for backup
- Review and clean up unused tags/correspondents
- Check storage usage regularly

### Security

- Change default admin password immediately
- Create separate user accounts for family members
- Enable 2FA if making public (via reverse proxy)
- Regular backups to external storage

---

## Resources

- **Official Documentation:** https://docs.paperless-ngx.com/
- **GitHub:** https://github.com/paperless-ngx/paperless-ngx
- **Community Forum:** https://github.com/paperless-ngx/paperless-ngx/discussions

---

## Support

For issues specific to MyNodeOne installation:
- Check logs: `kubectl logs -n paperless deployment/paperless`
- Check pod status: `kubectl get pods -n paperless`
- Restart: `kubectl rollout restart deployment/paperless -n paperless`

For Paperless-ngx features and usage:
- Visit official documentation
- Check GitHub issues
- Join community discussions
