const status = document.getElementById('status');
const reload = document.getElementById('reload');
document.getElementById('close').addEventListener('click', () => window.close());

async function readActiveTab() {
  try {
    const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
    if (!Number.isInteger(tab?.id) || tab.id <= 0 ||
        !tab.active || !/^https?:\/\//.test(tab.url ?? '')) {
      throw new Error('The popup did not receive an active website tab.');
    }
    status.textContent = `Tab ${tab.id}: ${new URL(tab.url).hostname}`;
    reload.disabled = false;
    reload.addEventListener('click', async () => {
      try {
        await chrome.tabs.reload(tab.id);
      } catch (error) {
        status.textContent = String(error);
      }
    });
  } catch (error) {
    status.textContent = String(error);
  }
}

readActiveTab();
