// Asks the host of the run once; the title says what came back.
chrome.runtime.sendNativeMessage('testing.nvim_spec.host', { ping: 1 }, (reply) => {
  document.title = reply ? `reply ${reply.pong}` : `error ${chrome.runtime.lastError.message}`;
});
