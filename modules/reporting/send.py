#!/usr/bin/env python3
"""Minimal SMTP2GO mail sender. Config via environment, body via stdin."""
import argparse
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage
from email.utils import formatdate, make_msgid


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"error: environment variable {name} is not set")
    return value


def build_message(sender, recipients, subject, body, html, text):
    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = recipients
    msg["Subject"] = subject
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain=sender.split("@")[-1].rstrip(">"))
    # RFC 3834: mark this as an auto-generated message so filters don't flag it
    # and autoresponders don't reply.  Also helps some spam classifiers.
    msg["Auto-Submitted"] = "auto-generated"

    # Set priority flags
    msg["Importance"] = "high"
    msg["X-Priority"] = "1"
    msg["X-MSMail-Priority"] = "High"

    if html:
        if text:
            msg.set_content(text, charset="utf-8")
            msg.add_alternative(body, subtype="html", charset="utf-8")
        else:
            # No plain-text alternative: send as text/html only (a placeholder
            # text/plain part is a strong spam signal, so don't fake one).
            msg.set_content(body, subtype="html", charset="utf-8")
    else:
        msg.set_content(body, charset="utf-8")
    return msg


def send(msg, host, port, user, password):
    ctx = ssl.create_default_context()
    if port in (465, 8465, 443):  # implicit TLS
        with smtplib.SMTP_SSL(host, port, context=ctx, timeout=30) as smtp:
            smtp.login(user, password)
            smtp.send_message(msg)
    else:  # STARTTLS (587, 2525, 8025, ...)
        with smtplib.SMTP(host, port, timeout=30) as smtp:
            smtp.starttls(context=ctx)
            smtp.login(user, password)
            smtp.send_message(msg)


def main():
    parser = argparse.ArgumentParser(
        description="Send a mail via SMTP2GO; body is read from stdin."
    )
    parser.add_argument("--subject", "-s", required=True)
    parser.add_argument("--to", help="override MAIL_TO (comma-separated)")
    parser.add_argument("--html", action="store_true", help="treat stdin as HTML")
    parser.add_argument(
        "--text-file", help="file with the plain-text alternative (used with --html)"
    )
    args = parser.parse_args()

    if sys.stdin.isatty():
        sys.exit(
            "error: no body on stdin, e.g.: echo hello | sudo send-mail --subject test"
        )
    body = sys.stdin.read()
    if not body.strip():
        sys.exit("error: empty body on stdin")

    text = None
    if args.text_file:
        try:
            with open(args.text_file) as f:
                text = f.read()
        except OSError as e:
            sys.exit(f"error: cannot read --text-file {args.text_file}: {e}")

    msg = build_message(
        sender=require_env("MAIL_FROM"),
        recipients=args.to or require_env("MAIL_TO"),
        subject=args.subject,
        body=body,
        html=args.html,
        text=text,
    )
    try:
        send(
            msg,
            host=os.environ.get("SMTP_HOST", "mail.smtp2go.com"),
            port=int(os.environ.get("SMTP_PORT", "587")),
            user=require_env("SMTP_USERNAME"),
            password=require_env("SMTP_PASSWORD"),
        )
    except (
        smtplib.SMTPException,
        OSError,
    ) as e:  # SMTP rejections, DNS/connect/TLS/timeouts
        sys.exit(f"error: sending failed: {type(e).__name__}: {e}")
    print("sent", file=sys.stderr)


if __name__ == "__main__":
    main()
