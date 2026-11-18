# Making pictures

`make_picture` makes a picture from a description with one of the person's picture models, or changes the newest picture in the conversation, and puts it in the conversation (#286). It is one of the [built-in tools](architecture.md#built-in-tools), **Make pictures**, key `pictures`, and it is **off by default**: an agent is offered it only once its settings turn it on (`toolsOn`), and the chat assistant is given it. An agent without it has nothing more in its prompt or tool definitions.

## Which models

The engine reaches picture models as code mode's `models.generateImages` does: through pi-ai's `Models.generateImages`, which finds the provider's key or sign-in itself (`src/pictures.ts`). Of pi-ai's providers, only **OpenRouter** has picture models (66 in its catalog as of this writing: Google's Gemini image models, OpenAI's GPT Image, FLUX, Recraft, Seedream and others). A custom endpoint cannot have one. So in practice the tool works for a person who has added an OpenRouter key.

Which model is asked: the first of a short list the person's providers have (`PREFERRED` in `src/pictures.ts`: Gemini 3.1 Flash Image, Gemini 2.5 Flash Image, GPT Image 1 Mini, GPT-5 Image Mini), chosen because they follow a description well, can change a picture they are given, and have a price in the catalog; else the first with a price; else the first. To change a picture, only a model that takes pictures is used. There is no setting to choose another yet.

## When there is none

The engine asks which picture models the person's providers can use as it starts and whenever a provider is signed in or out, or its key changes. While there are none:

- **The tool is offered to no one**, a chat included (the feature's `withheld`, which `toolsFor` and a chat's tools both leave out). A conversation gets it at its next message once there is one.
- **The model is told why**, in the `pictures` section of the prompt, in a conversation that would have the tool (a chat, or an agent whose settings turn it on): "You cannot make pictures here: none of the person's providers has a model that makes them (OpenRouter has them; the person can add a key in Settings › Providers). If they ask for a picture, say so plainly." Any other conversation is told nothing.
- **The person reads why** in the agent's settings, on the Make pictures line. The engine sends the app a `pictures` event, `{ models: [{ provider, id, name }], makers: [provider names] }`, as it connects and when the list changes.

## What it does

- `description`: what to show, in plain words. `change: true` sends the newest picture in the conversation with it, one the person attached or one made before (the last 400 entries are looked through), to be changed.
- The result is a line saying which model made it, what the model said if anything, and the picture, which is kept with the result like a screenshot. The model is sent the picture too, so a model that sees pictures can say what it made.
- A model that fails, or answers without a picture, is said plainly, with the provider's message.
- It **never asks for approval**: it changes nothing on the Mac. A call cut off by a restart is not made again, since the picture may have been made and paid for.

## What it costs

The picture model's answer comes with its token counts, which pi-ai prices from the catalog, and the tool returns them as its usage (pi durable's `pi.usage.tools`, under `make_picture`). The conversation's, the agent's and the day's totals in Usage count it, and so does the daily budget. It has no row of its own in Usage's list of models, which lists the models that answered. In OpenRouter's catalog 21 of the 66 picture models have a price; the others count their tokens at no cost, though OpenRouter charges for them, which is one reason the preferred ones are priced. OpenRouter's own figure for a request (`usage.cost`) is not read: pi-ai's picture API leaves it out.

## In the conversation

The row reads "Made a picture: “a lighthouse at dusk”", with the model's name, and starts open, showing the picture; clicking it opens it larger.

## Checking it

`engine/test/pictures.ts` runs two engines. The first has no picture model: the tool is offered to no one, an agent that turned it on and a chat have the `pictures` section and an agent that did not has nothing, and the `pictures` event names OpenRouter. The second has a picture model on a stand-in server on 127.0.0.1 that answers as OpenRouter's picture API does (`PI2_DEMO_PICTURES`, which gives the demo provider a priced model, `demo-pictures`, on that server; any other host is ignored): the tool is offered to an agent that turned it on and to a chat, makes a picture that `conversation.image` returns, counts its cost, sends the newest picture with `change`, says plainly when there is nothing to change and when the model fails, and asks nothing. No real provider is called.
