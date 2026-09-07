<?php

use Illuminate\Foundation\Inspiring;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Schedule;

/*
|--------------------------------------------------------------------------
| Console Routes
|--------------------------------------------------------------------------
|
| Upstream's copy of this file, with one change: the inbound-email schedule is
| gated on the IMAP receiver actually being selected.
|
| `inbound-emails:process` resolves whichever InboundEmailProcessor
| `mail-receiver.default` names. The shipped default is `sendgrid`, whose
| processMessagesFromAllFolders() throws unconditionally — SendGrid delivers
| inbound mail through its own webhook, so there is nothing to poll. Running it
| every five minutes on a deployment that has not configured IMAP therefore
| writes a stack trace to the log 288 times a day and does no work.
|
| Set MAIL_RECEIVER_DRIVER=webklex-imap together with the IMAP_* variables to
| turn the poller on.
|
*/

Artisan::command('inspire', function () {
    $this->comment(Inspiring::quote());
})->purpose('Display an inspiring quote');

if (config('mail-receiver.default') === 'webklex-imap') {
    Schedule::command('inbound-emails:process')
        ->everyFiveMinutes()
        ->withoutOverlapping();
}
