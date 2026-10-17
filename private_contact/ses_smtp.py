"""Default-off SES SMTP adapter with captured and protected production factories.

Connection/TLS/login precede the service's consent fence. The service coordinates
SMTP submission with withdrawal and records its outcome before releasing that
fence. DATA is irreversible once invoked; lost replies remain unknown. No wire,
recipient, credential or transport diagnostics are logged or returned.
"""
import re
import smtplib
import ssl
from email.message import EmailMessage
from email.policy import SMTP


class SESSMTP:
    supports_submission_fence = True
    def __init__(self, *, connect, mode='disabled'):
        self.connect = connect
        self.production_ready = mode == 'production' and getattr(connect, 'production_ready', False) is True
        self.synthetic = mode == 'synthetic' and getattr(connect, 'synthetic', False) is True

    @staticmethod
    def _refusal(code):
        if type(code) is int and 400 <= code <= 499:
            return 'transient', None
        if type(code) is int and 500 <= code <= 599:
            return 'permanent', None
        return 'unknown', None

    @staticmethod
    def _wire(message, synthetic=True):
        if (not isinstance(message, dict) or set(message) != {'kind', 'recipient', 'code'}
                or message['kind'] not in ('verification', 'notice')
                or not isinstance(message['recipient'], str) or len(message['recipient']) > 254
                or not re.fullmatch(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}", message['recipient'])
                or synthetic and not message['recipient'].endswith('.invalid')
                or not isinstance(message['code'], str)
                or not re.fullmatch(r'[A-Za-z0-9_-]{1,256}', message['code'])):
            return None
        mail = EmailMessage(policy=SMTP)
        mail['From'] = 'notify@batonmusic.app'
        mail['To'] = message['recipient']
        mail['Reply-To'] = 'notify@batonmusic.app'
        mail['Subject'] = ('Synthetic ' if synthetic else '') + ('Baton contact verification' if message['kind'] == 'verification' else 'Baton private notice')
        purpose = ('Verify the contact you opted to connect.' if message['kind'] == 'verification'
                   else 'Open your originating Baton app to view the private notice and instructions.')
        expiry = '15 minutes' if message['kind'] == 'verification' else '4 hours'
        prefix = 'SYNTHETIC LOCAL EXERCISE ONLY\n' if synthetic else ''
        mail.set_content(f'{prefix}{purpose}\nCode: {message["code"]}\n'
                         f'This code expires after {expiry}.\nIntake: notify@batonmusic.app\n')
        return mail.as_bytes()

    def send(self, message, *, submit=None):
        if not self.synthetic and not self.production_ready:
            return 'permanent', None
        try:
            wire = self._wire(message, synthetic=self.synthetic)
        except Exception:
            return 'permanent', None
        if wire is None:
            return 'permanent', None
        connection = None
        data_started = False
        try:
            connection = self.connect()
            def stages(authorized):
                nonlocal data_started
                for command, value in ((connection.mail, 'notify@batonmusic.app'),
                                       (connection.rcpt, message['recipient'])):
                    if not authorized():
                        return 'cancelled', None
                    code, _ = command(value)
                    if type(code) is not int or code != 250:
                        return self._refusal(code)
                if not authorized():
                    return 'cancelled', None
                # smtplib.data owns 354/body/final response. From invocation,
                # a lost reply conservatively fences retry as unknown.
                data_started = True
                try:
                    code, reply = connection.data(wire)
                    if type(code) is not int or code != 250:
                        return self._refusal(code)
                    if not isinstance(reply, bytes):
                        return 'unknown', None
                    match = re.fullmatch(rb'Ok ([A-Za-z0-9_-]{1,256})', reply)
                    return ('accepted', match.group(1).decode('ascii')) if match else ('unknown', None)
                except smtplib.SMTPDataError as error:
                    return self._refusal(error.smtp_code)
                except Exception:
                    return 'unknown', None
            def transmit(authorized):
                try:
                    return stages(authorized)
                except smtplib.SMTPResponseException as error:
                    return ('unknown', None) if data_started else self._refusal(error.smtp_code)
                except (OSError, smtplib.SMTPServerDisconnected):
                    return ('unknown', None) if data_started else ('transient', None)
                except Exception:
                    return 'unknown', None
            return submit(transmit) if submit is not None else transmit(lambda: True)
        except smtplib.SMTPDataError as error:
            # An explicit negative DATA reply confirms nonacceptance; neither
            # a timeout nor an arbitrary transport exception provides that proof.
            return self._refusal(error.smtp_code)
        except smtplib.SMTPResponseException as error:
            return ('unknown', None) if data_started else self._refusal(error.smtp_code)
        except (OSError, smtplib.SMTPServerDisconnected):
            return ('unknown', None) if data_started else ('transient', None)
        except Exception:
            return 'unknown', None
        finally:
            if connection is not None:
                try:
                    connection.close()
                except Exception:
                    # Closing after a confirmed 250 cannot undo acceptance.
                    pass


class SMTPConnect:
    """Existing scoped sender input only; TLS required, bounded and never logged."""
    production_ready = True

    def __init__(self, *, username: str, password: str):
        if not username or not password or any(char in username + password for char in '\r\n'):
            raise ValueError('configuration')
        self.username, self.password = username, password

    def __call__(self):
        connection = smtplib.SMTP('email-smtp.us-east-1.amazonaws.com', 587, timeout=8)
        try:
            connection.ehlo()
            connection.starttls(context=ssl.create_default_context())
            connection.ehlo()
            connection.login(self.username, self.password)
            return connection
        except Exception:
            connection.close()
            raise OSError('unavailable') from None
