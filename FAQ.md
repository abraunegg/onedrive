<details>
<summary>1. What do I need to type in cli so that only one folder gets downloaded?</summary>
<blockquote>If that folder is called <strong>Example</strong> you need to type <code>onedrive --synchronize --single-directory 'Example'</code></blockquote>
</details>

<details>
<summary>2. If I use the <code>onedrive --synchronize --single-directory</code> command, does the sync occurs automatically in the background when I edit files in the local storage?</summary>
<blockquote>No, there is no automatic sync occurring. However, if you switch the flag <code>--synchronize</code> for <code>--monitor</code> this will continually sync until you exit the application.</blockquote>
</details>

<details>
<summary>3. Should I have to create and customize the config file?</summary>
<blockquote>Generally you do not need to do this unless you want to change some of the default options. Best read the <code>help / man page</code> for assistance on the configuration options.</blockquote>
</details>

<details>
<summary>4. Do I need to create the sync_list file?</summary>
<blockquote>Generally no - you do not need to create this file, unless you want to be super specific about what needs to be synced.</blockquote>
</details>

<details>
<summary>5. I need to run onedrive as a system service to get automatic sync. What should I do?</summary>
<blockquote>Generally, the best way to configure automatic and constant sync in the background to occur is to use the flag <code>--monitor</code>, as already stated in the answer of the question <strong>#2</strong>.</blockquote>
</details>
