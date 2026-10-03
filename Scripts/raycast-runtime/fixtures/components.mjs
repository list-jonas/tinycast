// Runtime fixtures for the component surface: lists, details, forms, navigation, menu bar and command lifecycles.

import { check, describeTree, findNode, run, wait } from "./kit.mjs";

const listSource = `
import { List, ActionPanel, Action, Icon } from "@raycast/api";
import { useState } from "react";

export default function Command() {
  const [count, setCount] = useState(0);
  return (
    <List
      searchBarPlaceholder="Search…"
      searchBarAccessory={
        <List.Dropdown tooltip="Filter" onChange={() => {}}>
          <List.Dropdown.Item title="All" value="all" />
          <List.Dropdown.Item title="Active" value="active" />
        </List.Dropdown>
      }
    >
      <List.Section title="Main">
        <List.Item
          id="item-1"
          title={"Count is " + count}
          accessories={[{ text: "Tag" }, { icon: Icon.Star }]}
          actions={
            <ActionPanel>
              <Action title="Bump" onAction={() => setCount((c) => c + 1)} />
            </ActionPanel>
          }
        />
      </List.Section>
    </List>
  );
}
`;

const detailSource = `
import { Detail } from "@raycast/api";

export default function Command() {
  return (
    <Detail
      markdown="# Hello world"
      metadata={
        <Detail.Metadata>
          <Detail.Metadata.Label title="Author" text="Ada" />
          <Detail.Metadata.Separator />
          <Detail.Metadata.TagList title="Tags">
            <Detail.Metadata.TagList.Item text="fast" color="#00ff00" />
          </Detail.Metadata.TagList>
          <Detail.Metadata.Link title="Link" target="https://example.com" text="Home" />
        </Detail.Metadata>
      }
    />
  );
}
`;

const fragmentDetailSource = `
import { List } from "@raycast/api";

export default function Command() {
  return (
    <List>
      <List.Item
        title="TOTP"
        detail={
          <>
            <List.Item.Detail markdown="30s remaining" />
            <List.Item.Detail metadata={<List.Item.Detail.Metadata><List.Item.Detail.Metadata.Label title="Code" text="123456" /></List.Item.Detail.Metadata>} />
          </>
        }
      />
    </List>
  );
}
`;

const formSource = `
import { Form, ActionPanel, Action } from "@raycast/api";

export default function Command() {
  return (
    <Form actions={<ActionPanel><Action.SubmitForm title="Save" onSubmit={(values) => { globalThis.__submitted = values; }} /></ActionPanel>}>
      <Form.TextField id="name" title="Name" defaultValue="Ada" />
      <Form.TextArea id="bio" title="Bio" defaultValue="" />
      <Form.Checkbox id="agree" label="I agree" defaultValue={true} />
      <Form.Dropdown id="role" title="Role" defaultValue="dev">
        <Form.Dropdown.Item value="dev" title="Developer" />
      </Form.Dropdown>
      <Form.TagPicker id="tags" title="Tags" defaultValue={["swift"]}>
        <Form.TagPicker.Item value="swift" title="Swift" />
      </Form.TagPicker>
      <Form.DatePicker id="when" title="When" defaultValue={new Date("2026-04-18T10:00:00Z")} />
      <Form.Separator />
      <Form.Description title="Info" text="All fields are saved locally." />
    </Form>
  );
}
`;

const navigationSource = `
import { List, ActionPanel, Action, useNavigation, Detail } from "@raycast/api";

function Subscreen() {
  return <Detail markdown="# Subscreen" />;
}

export default function Command() {
  const { push } = useNavigation();
  return (
    <List>
      <List.Item
        title="Push"
        actions={
          <ActionPanel>
            <Action title="Open subscreen" onAction={() => push(<Subscreen />)} />
          </ActionPanel>
        }
      />
    </List>
  );
}
`;

const noViewSource = `
import { Clipboard, showHUD } from "@raycast/api";

export default async function Command() {
  await Clipboard.copy("from no-view");
  await showHUD("done");
  globalThis.__ranNoView = true;
}
`;

const asyncSource = `
import { List } from "@raycast/api";
import { useEffect, useState } from "react";

export default function Command() {
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    const timer = setTimeout(() => {
      setItems(["alpha", "beta"]);
      setLoading(false);
    }, 20);
    return () => clearTimeout(timer);
  }, []);
  return (
    <List isLoading={loading}>
      {items.map((item) => <List.Item key={item} title={item} />)}
    </List>
  );
}
`;

const errorSource = `
export default function Command() {
  throw new Error("kaboom");
}
`;

export async function runComponentFixtures() {
  await run("List with sections, actions and a dropdown", listSource, "view", async (harness) => {
    const tree = harness.state.trees.at(-1);
    const dump = tree ? describeTree(tree) : "";
    check("renders a screen", dump.includes("<__screen active=true>"));
    check("renders the List", dump.includes("<List"));
    check("keeps searchBarAccessory as a prop", dump.includes("searchBarAccessory=<List.Dropdown>"));
    check("renders a section with items", dump.includes("<List.Section") && dump.includes("<List.Item"));
    check("serializes accessories", dump.includes("accessories=[2]"));
    check("hoists actions into a prop", dump.includes("actions=<ActionPanel>"));
    check("defaults filtering to true", dump.includes("filtering=true"));

    // Bump the counter through the action's handler and confirm the re-render.
    const item = findNode(tree, "List.Item");
    const panel = item.props.actions;
    const bump = panel.children.find((child) => child.type === "Action");
    check("action carries a dispatchable handler", !!bump?.props?.onAction?.$fn, JSON.stringify(bump?.props));
    harness.dispatch("s1", bump.props.onAction.$fn);
    await wait();
    check("re-renders after the action", describeTree(harness.state.trees.at(-1)).includes("Count is 1"));
  });

  await run("Detail with metadata", detailSource, "view", async (harness) => {
    const dump = describeTree(harness.state.trees.at(-1));
    check("renders Detail", dump.includes("<Detail"));
    check("hoists metadata", dump.includes("metadata=<Detail.Metadata>"));
    const metadata = findNode(harness.state.trees.at(-1), "Detail").props.metadata;
    const kinds = metadata.children.map((child) => child.type);
    check(
      "metadata children in order",
      JSON.stringify(kinds) ===
        JSON.stringify([
          "Detail.Metadata.Label",
          "Detail.Metadata.Separator",
          "Detail.Metadata.TagList",
          "Detail.Metadata.Link",
        ]),
      JSON.stringify(kinds),
    );
  });

  await run("List.Item.Detail split across a Fragment", fragmentDetailSource, "view", async (harness) => {
    const detail = findNode(harness.state.trees.at(-1), "List.Item").props.detail;
    check("keeps the markdown from the first sibling", detail.props.markdown === "30s remaining", JSON.stringify(detail.props));
    check("keeps the metadata from the second sibling", detail.props.metadata?.type === "Detail.Metadata", JSON.stringify(detail.props));
  });

  await run("Form fields and submit", formSource, "view", async (harness) => {
    const tree = harness.state.trees.at(-1);
    const form = findNode(tree, "Form");
    const types = form.children.map((child) => child.type);
    check(
      "all field types render",
      ["Form.TextField", "Form.TextArea", "Form.Checkbox", "Form.Dropdown", "Form.TagPicker", "Form.DatePicker", "Form.Separator", "Form.Description"].every(
        (type) => types.includes(type),
      ),
      JSON.stringify(types),
    );
    const field = form.children.find((child) => child.type === "Form.TextField");
    check("field exposes its value", field.props.value === "Ada", JSON.stringify(field.props));
    check("field has a change handler", !!field.props.onTinycastChange?.$fn);

    harness.dispatch("s1", field.props.onTinycastChange.$fn, ["Grace"]);
    await wait();
    const submit = findNode(harness.state.trees.at(-1), "Action");
    harness.dispatch("s1", submit.props.onAction.$fn);
    await wait();
    const values = harness.call("globalThis.__submitted");
    check(
      "submit collects every field value",
      values?.name === "Grace" && values.agree === true && values.role === "dev" && Array.isArray(values.tags),
      JSON.stringify(values),
    );
  });

  await run("Navigation push and pop", navigationSource, "view", async (harness) => {
    const push = findNode(harness.state.trees.at(-1), "Action");
    harness.dispatch("s1", push.props.onAction.$fn);
    await wait();
    let screens = harness.state.trees.at(-1).children.filter((child) => child.type === "__screen");
    check("two screens after push", screens.length === 2, String(screens.length));
    check("the pushed screen is active", screens[1].props.active === true);
    check("the first screen is inactive but mounted", screens[0].props.active === false);
    check("navigation depth reported", harness.state.navigationDepth === 2, String(harness.state.navigationDepth));

    harness.call('__tinycast.popNavigation("s1")');
    await wait();
    screens = harness.state.trees.at(-1).children.filter((child) => child.type === "__screen");
    check("one screen after pop", screens.length === 1, String(screens.length));
  });

  await run("no-view command", noViewSource, "no-view", async (harness) => {
    check("ran to completion", harness.state.finished === true);
    check("ran the body", harness.call("globalThis.__ranNoView") === true);
    check(
      "used the clipboard and HUD host calls",
      harness.state.hostCalls.includes("clipboard.copy") && harness.state.hostCalls.includes("feedback.showHUD"),
      harness.state.hostCalls.join(", "),
    );
  });

  await run("timers drive an async render", asyncSource, "view", async (harness) => {
    check("starts loading", describeTree(harness.state.trees[0]).includes("isLoading=true"));
    await wait(120);
    const dump = describeTree(harness.state.trees.at(-1));
    check("finishes loading", dump.includes("isLoading=false"), dump);
    check("renders the resolved items", dump.includes("alpha") && dump.includes("beta"));
  });

  await run("Menu bar hooks, alternates and async actions", `
    import { MenuBarExtra } from "@raycast/api";
    import { useEffect, useState } from "react";
    function Alternate() {
      const [title] = useState("Alternate");
      return <MenuBarExtra.Item title={title} onAction={() => { globalThis.clicked = "alternate"; }} />;
    }
    export default function Command() {
      const [loading, setLoading] = useState(true);
      const [title, setTitle] = useState("Before");
      useEffect(() => { setLoading(false); }, []);
      return <MenuBarExtra title={title} isLoading={loading} tooltip="Usage">
        <MenuBarExtra.Section title="Providers">
          <MenuBarExtra.Item title="Refresh" alternate={<Alternate />} onAction={async (event) => {
            await new Promise(resolve => setTimeout(resolve, 40));
            globalThis.clicked = event.type;
            setTitle("After");
          }} />
        </MenuBarExtra.Section>
      </MenuBarExtra>;
    }
  `, "menu-bar", async (harness) => {
    const tree = harness.state.trees.at(-1);
    const root = findNode(tree, "MenuBarExtra");
    const item = findNode(tree, "MenuBarExtra.Item");
    check("menu-bar mounts hooks", root?.props.isLoading === false && !harness.state.finished);
    check("alternate mounts through a slot", item?.props.alternate?.props.title === "Alternate");
    check("alternate retains callback", typeof item?.props.alternate?.props.onAction?.$fn === "string");
    harness.call(`__tinycast.dispatch("s1", ${JSON.stringify(item.props.onAction.$fn)}, '[{"type":"right-click"}]', true)`);
    check("async action keeps session alive", !harness.state.finished);
    await wait(100);
    check("action receives click type", harness.call("globalThis.clicked") === "right-click");
    check("async action completes", harness.state.finished);
    check("action updates menu title", findNode(harness.state.trees.at(-1), "MenuBarExtra")?.props.title === "After");
  });

  await run("Menu bar can remove its item", `
    export default function Command() { return null; }
  `, "menu-bar", async (harness) => {
    check("null commits an empty screen", harness.state.trees.length > 0 && !findNode(harness.state.trees.at(-1), "MenuBarExtra"));
  });

  await run("Errors surface instead of crashing", errorSource, "view", async (harness) => {
    check("a throwing component reports a failure", harness.state.failures.some((message) => message.includes("kaboom")), harness.state.failures.join("|"));
  });
}
