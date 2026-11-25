defmodule Testor.Web.OpenAPI do
  @moduledoc "The OpenAPI 3.1 description of `/api/v1`, served at `GET /api/v1/openapi.json`."

  def spec do
    %{
      "openapi" => "3.1.0",
      "info" => %{
        "title" => "testor",
        "version" => to_string(Application.spec(:testor, :vsn) || "0.0.0"),
        "description" =>
          "Test runs a testor runner recorded: their status, spec results, output, screenshots and " <>
            "artifacts, the runner's device stats and maintenance. Authentication (when the runner " <>
            "has users): HTTP Basic, or a Bearer token from POST /auth/token. Scopes: read, operate, " <>
            "maintain. State-changing requests without a Bearer token need a JSON body or the " <>
            "header X-Testor: 1.",
        "license" => %{"name" => "MIT", "identifier" => "MIT"}
      },
      "servers" => [%{"url" => "/api/v1"}],
      "security" => [%{"basic" => []}, %{"bearer" => []}],
      "tags" => [
        %{"name" => "auth"},
        %{"name" => "runs"},
        %{"name" => "runner"},
        %{"name" => "maintenance"},
        %{"name" => "jobs"},
        %{"name" => "gates"},
        %{"name" => "approvals"},
        %{"name" => "agents"}
      ],
      "paths" => paths(),
      "components" => %{
        "securitySchemes" => %{
          "basic" => %{"type" => "http", "scheme" => "basic"},
          "bearer" => %{"type" => "http", "scheme" => "bearer", "bearerFormat" => "JWT"}
        },
        "parameters" => %{
          "id" => %{
            "name" => "id",
            "in" => "path",
            "required" => true,
            "description" => "Run id, yyyyMMdd-HHmmss-<6 hex> (UTC)",
            "schema" => %{"type" => "string", "pattern" => "^[\\w.-]+$"}
          }
        },
        "responses" => %{
          "Error" => %{
            "description" => "An error",
            "content" => json_content(ref("Error"))
          }
        },
        "schemas" => schemas()
      }
    }
  end

  defp paths do
    %{
      "/health" => %{
        "get" =>
          op("runner", "Liveness and versions (details with the read scope)", ref("Health"), security: [%{}])
      },
      "/openapi.json" => %{
        "get" => op("runner", "This document", %{"type" => "object"}, security: [%{}])
      },
      "/auth/token" => %{
        "post" =>
          op(
            "auth",
            "Issue a Bearer token (OAuth 2.0 client credentials, with Basic credentials)",
            ref("Token"),
            security: [%{"basic" => []}],
            body: %{
              "type" => "object",
              "properties" => %{
                "grant_type" => %{"const" => "client_credentials"},
                "scope" => %{
                  "type" => "string",
                  "description" => "space-separated subset of the user's scopes"
                },
                "expires_in" => %{"type" => "integer", "minimum" => 60, "description" => "seconds"}
              }
            },
            form: true
          )
      },
      "/auth/me" => %{
        "get" => op("auth", "Who the request authenticates as, and its scopes", ref("Me"))
      },
      "/runs" => %{
        "get" =>
          op("runs", "Runs, newest first, filtered and paged", page(ref("Run")),
            params: [
              query("status", %{"enum" => Testor.Query.statuses()}),
              query("project", %{"type" => "string"}),
              query("kind", %{"type" => "string"}, "the task's name (test, lint, ...)"),
              query("q", %{"type" => "string"}, "substring of the project, kind or command"),
              query("before", %{"type" => "string"}, "the next page: the previous answer's `next`"),
              query("limit", %{"type" => "integer", "minimum" => 1, "maximum" => 500, "default" => 50})
            ]
          )
      },
      "/runs/{id}" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "get" => op("runs", "A run, its spec files, screenshots and artifacts", ref("RunDetail")),
        "delete" => op("runs", "Delete a finished run (scope operate)", %{"type" => "object"})
      },
      "/runs/{id}/attestation" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "get" =>
          op(
            "runs",
            "The run's signed attestation: an in-toto statement in a DSSE envelope (Ed25519)",
            %{"type" => "object"}
          )
      },
      "/projects/{project}/flaky" => %{
        "parameters" => [
          %{"name" => "project", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}
        ],
        "get" =>
          op(
            "runs",
            "Spec files that both passed and failed on the same clean commit",
            %{"type" => "object"},
            params: [query("kind", %{"type" => "string"}, "only runs of this task")]
          )
      },
      "/jobs" => %{
        "get" =>
          op("jobs", "Jobs, newest first", %{"type" => "object"},
            params: [query("status", %{"enum" => Testor.Jobs.statuses()}, "only jobs with this status")]
          ),
        "post" =>
          op(
            "jobs",
            "Queue a job (scope execute; off until execution.enabled): {project, kind, labels?, ref?}",
            %{"type" => "object"}
          )
      },
      "/jobs/{id}" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "get" => op("jobs", "A job", %{"type" => "object"})
      },
      "/jobs/{id}/cancel" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "post" => op("jobs", "Cancel a job (scope execute)", %{"type" => "object"})
      },
      "/approvals" => %{
        "get" =>
          op("approvals", "What AI agents asked to do and a person must approve (?status=pending)", %{
            "type" => "object"
          })
      },
      "/approvals/{id}" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "get" => op("approvals", "An approval, with the tool's result once done", %{"type" => "object"})
      },
      "/approvals/{id}/approve" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "post" =>
          op("approvals", "Approve: testor calls the tool as the agent that asked (its tool's scope)", %{
            "type" => "object"
          })
      },
      "/approvals/{id}/deny" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "post" => op("approvals", "Deny: nothing is done", %{"type" => "object"})
      },
      "/gates" => %{
        "get" => op("gates", "config.json's release gates, or why one is left out", %{"type" => "object"})
      },
      "/gates/{name}" => %{
        "parameters" => [
          %{"name" => "name", "in" => "path", "required" => true, "schema" => %{"type" => "string"}},
          %{"name" => "commit", "in" => "query", "required" => true, "schema" => %{"type" => "string"}}
        ],
        "get" =>
          op("gates", "Whether a commit passes the gate: each kind's latest signed run of it", %{
            "type" => "object"
          })
      },
      "/schedules" => %{
        "get" =>
          op("jobs", "config.json's schedules, each with its next time (UTC) or why it is left out", %{
            "type" => "object"
          })
      },
      "/agent/lease" => %{
        "post" =>
          op(
            "agents",
            "Take the oldest job this agent can run, waiting up to `wait` seconds (scope agent): 200 or 204",
            %{"type" => "object"}
          )
      },
      "/agent/jobs/{id}/heartbeat" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "post" =>
          op("agents", "Renew the lease; answers whether to cancel (scope agent)", %{"type" => "object"})
      },
      "/agent/jobs/{id}/token" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "post" =>
          op("agents", "The held job's identity token for an audience of jobTokens (scope agent)", %{
            "type" => "object"
          })
      },
      "/agent/jobs/{id}/run" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "put" => op("agents", "A remote agent's run record for the job (scope agent)", %{"type" => "object"})
      },
      "/agent/jobs/{id}/log" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "post" =>
          op("agents", "Append a chunk (1 MB at most) to the job's run log at ?offset= (scope agent)", %{
            "type" => "object"
          })
      },
      "/agent/jobs/{id}/files/{area}/{path}" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "put" =>
          op(
            "agents",
            "A screenshot or artifact of the job's run (area: screenshots, artifacts) (scope agent)",
            %{"type" => "object"}
          )
      },
      "/agent/jobs/{id}/attestation" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "put" =>
          op("agents", "The agent's own signed attestation of the job's run (ECDSA P-256) (scope agent)", %{
            "type" => "object"
          })
      },
      "/agents" => %{
        "get" => op("agents", "Agents and the signing keys pinned to them", %{"type" => "object"})
      },
      "/agent/jobs/{id}/finish" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "post" =>
          op("agents", "Report the job's end: {exitCode, error?} (scope agent)", %{"type" => "object"})
      },
      "/audit" => %{
        "get" =>
          op(
            "runner",
            "The audit trail's last entries and whether the whole chain verifies (scope maintain)",
            %{"type" => "object"},
            params: [
              query(
                "limit",
                %{"type" => "integer", "minimum" => 1, "maximum" => 1000, "default" => 100},
                "entries"
              )
            ]
          )
      },
      "/attestation/key" => %{
        "get" =>
          op("runs", "The public key attestations are signed with (PEM) and its id", %{
            "type" => "object",
            "properties" => %{
              "algorithm" => %{"const" => "ed25519"},
              "keyid" => %{"type" => "string"},
              "publicKey" => %{"type" => "string"}
            }
          })
      },
      "/runs/{id}/log" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "get" =>
          op("runs", "The end of a run's output, as text", nil,
            text: true,
            params: [
              query(
                "tail",
                %{"type" => "integer", "default" => 524_288, "maximum" => 8_388_608},
                "bytes from the end"
              ),
              query(
                "grep",
                %{"type" => "string"},
                "only the lines containing it (case-insensitive), numbered"
              ),
              query(
                "context",
                %{"type" => "integer", "minimum" => 0, "maximum" => 20},
                "lines around each match"
              )
            ]
          )
      },
      "/runs/{id}/events" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "get" =>
          op("runs", "Server-sent events of one run: snapshot, log, specs, run, screenshots, artifacts", nil,
            sse: true
          )
      },
      "/runs/{id}/cancel" => %{
        "parameters" => [%{"$ref" => "#/components/parameters/id"}],
        "post" => op("runs", "Kill a running run's process tree (scope operate)", ref("Run"))
      },
      "/events" => %{
        "get" =>
          op("runner", "Server-sent events of everything: snapshot, run, live, sessions, stats, device", nil,
            sse: true
          )
      },
      "/projects" => %{
        "get" => op("runs", "The latest run of each project and task", list(ref("Project")))
      },
      "/sessions" => %{
        "get" =>
          op(
            "runner",
            "PowerShell sessions in the workspaces that run.ps1 did not start",
            list(%{"type" => "object"})
          )
      },
      "/stats" => %{
        "get" =>
          op("runner", "Disk space, screenshot and artifact usage, last cleanup", %{"type" => "object"})
      },
      "/device" => %{
        "get" => op("runner", "Device stats: static facts, latest sample, history", %{"type" => "object"})
      },
      "/screenshots" => %{"get" => op("runs", "Every screenshot, newest first", list(%{"type" => "object"}))},
      "/artifacts" => %{
        "get" => op("runs", "Every run that kept artifacts, newest first", list(%{"type" => "object"}))
      },
      "/cleanup" => %{
        "post" => op("maintenance", "Run the retention janitor now (scope operate)", %{"type" => "object"})
      },
      "/maintenance" => %{"get" => op("maintenance", "The last maintenance scan", %{"type" => "object"})},
      "/maintenance/scan" => %{
        "post" =>
          op(
            "maintenance",
            "Measure the maintenance targets, in the background (scope operate)",
            %{"type" => "object"},
            status: "202"
          )
      },
      "/maintenance/clean" => %{
        "post" =>
          op(
            "maintenance",
            "Delete targets of the last scan (scope maintain; maintenance.enabled)",
            %{"type" => "object"},
            status: "202",
            body: %{
              "type" => "object",
              "required" => ["scanId", "targets"],
              "properties" => %{
                "scanId" => %{"type" => "string"},
                "targets" => %{"type" => "array", "minItems" => 1, "items" => %{"type" => "string"}}
              }
            }
          )
      }
    }
  end

  defp schemas do
    %{
      "Error" => %{
        "type" => "object",
        "required" => ["error"],
        "properties" => %{
          "error" => %{
            "type" => "object",
            "properties" => %{"code" => %{"type" => "string"}, "message" => %{"type" => "string"}}
          }
        }
      },
      "Health" => %{
        "type" => "object",
        "properties" => %{
          "ok" => %{"type" => "boolean"},
          "app" => %{"type" => "string"},
          "version" => %{"type" => "string"},
          "auth" => %{"type" => "boolean"}
        }
      },
      "Token" => %{
        "type" => "object",
        "properties" => %{
          "access_token" => %{"type" => "string"},
          "token_type" => %{"const" => "Bearer"},
          "expires_in" => %{"type" => "integer"},
          "scope" => %{"type" => "string"}
        }
      },
      "Me" => %{
        "type" => "object",
        "properties" => %{
          "authEnabled" => %{"type" => "boolean"},
          "user" => %{"type" => ["string", "null"]},
          "via" => %{"enum" => ["none", "basic", "bearer"]},
          "scopes" => %{"type" => "array", "items" => %{"type" => "string"}},
          "expiresAt" => %{"type" => ["integer", "null"]}
        }
      },
      "Summary" => %{
        "type" => ["object", "null"],
        "properties" => Map.new(~w(specs passed failed skipped tests), &{&1, %{"type" => "integer"}})
      },
      "Run" => %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string"},
          "project" => %{"type" => "string"},
          "kind" => %{"type" => "string"},
          "command" => %{"type" => "string"},
          "status" => %{"enum" => Testor.Query.statuses()},
          "exitCode" => %{"type" => ["integer", "null"]},
          "startedAt" => %{"type" => "string", "format" => "date-time"},
          "endedAt" => %{"type" => ["string", "null"], "format" => "date-time"},
          "durationMs" => %{"type" => ["integer", "null"]},
          "summary" => ref("Summary"),
          "warning" => %{"type" => "string"},
          "error" => %{"type" => "string"},
          "screenshots" => %{"type" => "integer"},
          "artifacts" => %{"type" => "integer"},
          "currentSpec" => %{"type" => ["string", "null"]},
          "actor" => %{
            "type" => "object",
            "description" =>
              "who started the run: the runner's account and SSH client address, and who the workstation said it was (informative)",
            "properties" => %{
              "user" => %{"type" => "string"},
              "client" => %{"type" => ["string", "null"]},
              "declared" => %{"type" => ["string", "null"]}
            }
          }
        }
      },
      "Spec" => %{
        "type" => "object",
        "properties" => %{
          "file" => %{"type" => "string"},
          "runner" => %{"type" => "string"},
          "tests" => %{"type" => ["integer", "null"]},
          "failed" => %{"type" => ["integer", "null"]},
          "skipped" => %{"type" => ["integer", "null"]},
          "durationMs" => %{"type" => ["integer", "null"]},
          "status" => %{"type" => "string"}
        }
      },
      "File" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "url" => %{"type" => "string", "description" => "a signed link while authentication is on"},
          "bytes" => %{"type" => "integer"},
          "kind" => %{"type" => "string"}
        }
      },
      "RunDetail" => %{
        "type" => "object",
        "properties" => %{
          "run" => ref("Run"),
          "specs" => %{"type" => "array", "items" => ref("Spec")},
          "screenshots" => %{"type" => "array", "items" => ref("File")},
          "artifacts" => %{"type" => "array", "items" => ref("File")},
          "logBytes" => %{"type" => "integer"}
        }
      },
      "Project" => %{
        "type" => "object",
        "properties" => %{
          "project" => %{"type" => "string"},
          "kind" => %{"type" => "string"},
          "runs" => %{"type" => "integer"},
          "latest" => ref("Run"),
          "recent" => %{"type" => "array", "items" => %{"type" => "string"}}
        }
      }
    }
  end

  defp op(tag, summary, schema, opts \\ []) do
    content =
      cond do
        opts[:text] -> %{"text/plain" => %{"schema" => %{"type" => "string"}}}
        opts[:sse] -> %{"text/event-stream" => %{"schema" => %{"type" => "string"}}}
        true -> json_content(schema)
      end

    op = %{
      "tags" => [tag],
      "summary" => summary,
      "responses" => %{
        (opts[:status] || "200") => %{"description" => "OK", "content" => content},
        "default" => %{"$ref" => "#/components/responses/Error"}
      }
    }

    op = if opts[:params], do: Map.put(op, "parameters", opts[:params]), else: op
    op = if opts[:security], do: Map.put(op, "security", opts[:security]), else: op

    case opts[:body] do
      nil ->
        op

      body ->
        content = json_content(body)

        content =
          if opts[:form],
            do: Map.put(content, "application/x-www-form-urlencoded", %{"schema" => body}),
            else: content

        Map.put(op, "requestBody", %{"required" => false, "content" => content})
    end
  end

  defp query(name, schema, description \\ nil) do
    param = %{"name" => name, "in" => "query", "schema" => schema}
    if description, do: Map.put(param, "description", description), else: param
  end

  defp json_content(schema), do: %{"application/json" => %{"schema" => schema}}
  defp ref(name), do: %{"$ref" => "#/components/schemas/#{name}"}

  defp list(item),
    do: %{"type" => "object", "properties" => %{"data" => %{"type" => "array", "items" => item}}}

  defp page(item) do
    %{
      "type" => "object",
      "properties" => %{
        "data" => %{"type" => "array", "items" => item},
        "next" => %{"type" => ["string", "null"]}
      }
    }
  end
end
