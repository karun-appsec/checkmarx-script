import pandas as pd
import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.base import MIMEBase
from email import encoders
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

# -----------------------------
# CONFIG
# -----------------------------
# Key Vault configuration
key_vault_url = "https://akv-tdsif-sif-ci-sec-01.vault.azure.net/"

# Authenticate
credential = DefaultAzureCredential()
client = SecretClient(vault_url=key_vault_url, credential=credential)

# Fetch secrets from Key Vault
sender_email = client.get_secret("infosec-email").value
sender_password = client.get_secret("infosec-pswd").value

# Recipients list
recipients = ["t_enaganti.kkumar@tatadigital.com"]

# CC (always included)
cc_list = ["t_enaganti.kkumar@tatadigital.com"]

# SMTP Configuration
smtp_server = "smtp.office365.com"
smtp_port = 587

# Input file (Excel) and sheet index
input_file = "NonFS_NonCompliant_Repos.xlsx"
sheet_index = 0  # first sheet

# -----------------------------
# FUNCTION: Build HTML Table
# -----------------------------
def build_html_table(df):
    html_table = """
    <table border="1" cellspacing="0" cellpadding="5" style="border-collapse: collapse; width: 100%; word-wrap: break-word;">
        <tr style="background-color: lightblue; font-weight: bold; text-align: center;">
    """

    # Header
    for col in df.columns:
        html_table += f"<th style='padding: 5px; white-space: nowrap;'>{col}</th>"
    html_table += "</tr>"

    # Rows
    for _, row in df.iterrows():
        html_table += "<tr>"
        for col in df.columns:
            value = row[col] if pd.notna(row[col]) else ""  # keep blank if NaN
            html_table += f"<td style='padding: 5px; word-wrap: break-word;'>{value}</td>"
        html_table += "</tr>"

    html_table += "</table>"
    return html_table

# -----------------------------
# FUNCTION: Send Email
# -----------------------------
def send_email(to_emails, cc_emails, subject, html_content, attachment_path=None):
    msg = MIMEMultipart()
    msg["From"] = sender_email
    msg["To"] = ", ".join(to_emails)
    msg["Cc"] = ", ".join(cc_emails)
    msg["Subject"] = subject

    # Attach HTML content
    msg.attach(MIMEText(html_content, "html"))

    # Attach file if provided
    if attachment_path:
        with open(attachment_path, "rb") as f:
            part = MIMEBase("application", "octet-stream")
            part.set_payload(f.read())
        encoders.encode_base64(part)
        part.add_header(
            "Content-Disposition",
            f"attachment; filename={attachment_path.split('/')[-1]}"
        )
        msg.attach(part)

    all_recipients = to_emails + cc_emails

    try:
        server = smtplib.SMTP(smtp_server, smtp_port)
        server.starttls()
        server.login(sender_email, sender_password)
        server.sendmail(sender_email, all_recipients, msg.as_string())
        server.quit()
        print(f"✅ Email sent to: {', '.join(all_recipients)}")
    except Exception as e:
        print(f"❌ Failed to send email to {all_recipients}: {e}")

# -----------------------------
# MAIN SCRIPT
# -----------------------------
def main():
    # Read Excel sheet
    df = pd.read_excel(input_file, sheet_name=sheet_index)

    # Build HTML table
    html_table = build_html_table(df)

    # Email content
    html_content = f"""
    <p>Hi All,</p>
    <p>As we are aware that CheckMarx policy enforcement is implemented in repos on all branches, however we found non-compliance on repos for the following cases:</p>
    <ul>
        <li>Branch protection policy check - Status checks to pass before merging is disabled</li>
        <li>If Branch Protection policy is enabled, the corresponding pipeline is missing for the repo</li>
        <li>If above two conditions are met, PR validation check is missing</li>
    </ul>
    <p>Below is the count of non-compliant repos per application, please share the ETA as per the table:</p>
    {html_table}
    <p>Request you to take action on the non-compliant repos as per attached sheet.</p>
    <p>Please feel free to connect @Enaganti KKumar or @Sahil Gupta in case of any queries.</p>
    <p>Thanks,<br>Infosec Team</p>
    """

    # Send email with attachment
    send_email(recipients, cc_list, "Non-Compliant NonFS Repos - Checkmarx Policy Enforcement -- testing", html_content, attachment_path=input_file)

if __name__ == "__main__":
    main()
